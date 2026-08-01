#!/usr/bin/env ruby
# frozen_string_literal: true
Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

require "date"
require "pathname"
require "yaml"

ROOT = Pathname.new(ENV.fetch("VAULT_ROOT", File.expand_path("../..", __dir__))).expand_path
COMMON_REQUIRED = %w[
  id type schema_version record_status created_at updated_at created_by updated_by tags
].freeze
COMMON_OPTIONAL = %w[
  name aliases merged_into created_by_run updated_by_run source_links source_urls data_notes
].freeze
PERSONAL_TYPES = %w[person interaction introduction commitment follow-up relationship dataset].freeze
RECORD_STATUSES = %w[active archived merged].freeze
ACTORS = %w[human agent].freeze
SENSITIVITIES = %w[normal private restricted].freeze
DATA_ORIGINS = %w[given_by_subject public third_party inferred mixed].freeze
CONFIDENCES = %w[confirmed probable possible disputed].freeze
RELATIONSHIP_STATUSES = %w[asserted retracted].freeze
ULID = /\A[0-9A-HJKMNP-TV-Z]{26}\z/
WIKILINK = /\A\[\[([^\]|#]+)(?:#[^\]|]+)?(?:\|[^\]]+)?\]\]\z/

errors = []
warnings = []

def frontmatter(path, errors)
  content = File.read(path.to_s, encoding: "UTF-8")
  return nil unless content.start_with?("---\n", "---\r\n")

  match = content.match(/\A---\s*\r?\n(.*?)\r?\n---\s*(?:\r?\n|\z)/m)
  unless match
    errors << "#{path.relative_path_from(ROOT)}: unclosed frontmatter"
    return nil
  end

  data = YAML.safe_load(match[1], permitted_classes: [Date, Time], aliases: false)
  unless data.is_a?(Hash)
    errors << "#{path.relative_path_from(ROOT)}: frontmatter must be a mapping"
    return nil
  end
  data.transform_keys(&:to_s)
rescue Psych::SyntaxError => error
  errors << "#{path.relative_path_from(ROOT)}: YAML error: #{error.message.lines.first.strip}"
  nil
end

def array(value)
  value.is_a?(Array) ? value : []
end

def flat_frontmatter?(data)
  data.values.none? do |value|
    value.is_a?(Hash) || (value.is_a?(Array) && value.any? { |item| item.is_a?(Hash) || item.is_a?(Array) })
  end
end

def link_target(value)
  return nil unless value.is_a?(String)

  match = value.match(WIKILINK)
  match && match[1]
end

def values_with_links(data)
  data.flat_map do |key, value|
    values = value.is_a?(Array) ? value : [value]
    values.map { |item| [key, item, link_target(item)] if link_target(item) }.compact
  end
end

def schema_files(relative_glob, errors)
  Dir.glob(ROOT.join(relative_glob).to_s).sort.map do |filename|
    path = Pathname.new(filename)
    data = frontmatter(path, errors)
    [path, data] if data
  end.compact
end

schemas = {}
schema_files("_System/Schema/Entity Types/*.md", errors).each do |path, data|
  key = data["schema_key"]
  if key.nil? || schemas.key?(key)
    errors << "#{path.relative_path_from(ROOT)}: missing or duplicate schema_key"
  else
    schemas[key] = data
  end
end

relationship_types = {}
schema_files("_System/Relationship Types/*.md", errors).each do |path, data|
  predicate = data["predicate"]
  if predicate.nil? || relationship_types.key?(predicate)
    errors << "#{path.relative_path_from(ROOT)}: missing or duplicate predicate"
  else
    relationship_types[predicate] = data
  end
end

excluded_prefixes = [".git/", ".obsidian/", "_System/Templates/", "_System/Schema/", "_System/Relationship Types/"]
markdown_paths = Dir.glob(ROOT.join("**/*.md").to_s, File::FNM_DOTMATCH).sort.map { |name| Pathname.new(name) }
notes = {}
canonical = []

markdown_paths.each do |path|
  relative = path.relative_path_from(ROOT).to_s
  notes[relative.sub(/\.md\z/, "")] = path
  next if excluded_prefixes.any? { |prefix| relative.start_with?(prefix) }

  data = frontmatter(path, errors)
  next unless data

  type = data["type"]
  next unless type
  unless schemas.key?(type)
    errors << "#{relative}: unknown canonical type #{type.inspect}"
    next
  end
  canonical << [path, relative, data, schemas.fetch(type)]
end

id_index = {}
canonical.each do |path, relative, data, _schema|
  id = data["id"]
  next unless id
  if id_index.key?(id)
    errors << "#{relative}: duplicate ID #{id}; first used by #{id_index[id]}"
  else
    id_index[id] = relative
  end
end

canonical_by_path = canonical.to_h { |path, relative, data, _schema| [relative.sub(/\.md\z/, ""), [path, data]] }

resolve_link = lambda do |relative, key, value|
  target = link_target(value)
  unless target
    errors << "#{relative}: #{key} must be a quoted wiki link"
    next nil
  end
  unless target.include?("/")
    errors << "#{relative}: #{key} must use a full vault-relative path: #{value}"
    next nil
  end
  target = target.sub(/\.md\z/, "")
  destination = notes[target]
  unless destination
    errors << "#{relative}: broken wiki link in #{key}: #{value}"
    next nil
  end
  canonical_by_path[target]&.last
end

canonical.each do |path, relative, data, schema|
  type = data["type"]
  status = data["record_status"]

  present = lambda do |field|
    value = data[field]
    data.key?(field) && !value.nil? && (!value.is_a?(String) || !value.strip.empty?)
  end

  COMMON_REQUIRED.each do |field|
    errors << "#{relative}: missing required field #{field}" unless present.call(field)
  end
  array(schema["required_fields"]).each do |field|
    next if status == "merged"
    errors << "#{relative}: missing required field #{field}" unless present.call(field)
  end

  errors << "#{relative}: canonical frontmatter must be flat" unless flat_frontmatter?(data)
  errors << "#{relative}: invalid record_status #{status.inspect}" unless RECORD_STATUSES.include?(status)
  errors << "#{relative}: schema_version must be 1" unless data["schema_version"] == 1
  errors << "#{relative}: created_by must be human or agent" unless ACTORS.include?(data["created_by"])
  errors << "#{relative}: updated_by must be human or agent" unless ACTORS.include?(data["updated_by"])
  errors << "#{relative}: created_by_run required for agent creation" if data["created_by"] == "agent" && !data["created_by_run"]
  errors << "#{relative}: updated_by_run required for agent update" if data["updated_by"] == "agent" && !data["updated_by_run"]

  id = data["id"].to_s
  prefix, suffix = id.split("_", 2)
  errors << "#{relative}: ID prefix must be #{schema['id_prefix']}_" unless prefix == schema["id_prefix"]
  errors << "#{relative}: ID must contain a valid 26-character ULID" unless suffix&.match?(ULID)

  folder_ok = array(schema["folder_prefixes"]).any? { |folder| relative.start_with?(folder) }
  errors << "#{relative}: file is outside allowed folders #{array(schema['folder_prefixes']).join(', ')}" unless folder_ok

  tags = array(data["tags"])
  array(schema["required_tags"]).each do |tag|
    errors << "#{relative}: missing required tag #{tag}" unless tags.include?(tag)
  end

  if schema["name_required"]
    errors << "#{relative}: name is required" unless data["name"].is_a?(String) && !data["name"].strip.empty?
    errors << "#{relative}: aliases must be a list" unless data["aliases"].is_a?(Array)
  elsif data.key?("name") || data.key?("aliases")
    errors << "#{relative}: #{type} must derive display text and omit name/aliases"
  end

  if schema["id_filename"] && path.basename(".md").to_s != id
    errors << "#{relative}: filename must equal immutable ID #{id}.md"
  end

  if status == "merged"
    errors << "#{relative}: merged record requires merged_into" unless data["merged_into"]
    next
  end

  if PERSONAL_TYPES.include?(type)
    errors << "#{relative}: invalid sensitivity" unless SENSITIVITIES.include?(data["sensitivity"])
    errors << "#{relative}: invalid data_origin" unless DATA_ORIGINS.include?(data["data_origin"])
  end

  values_with_links(data).each do |key, value, _target|
    resolve_link.call(relative, key, value)
  end

  if type == "person"
    errors << "#{relative}: invalid tier" unless %w[inner active dormant archive].include?(data["tier"])
    errors << "#{relative}: emails must be a list" if data.key?("emails") && !data["emails"].is_a?(Array)
    errors << "#{relative}: phones must be a list" if data.key?("phones") && !data["phones"].is_a?(Array)
    %w[primary_email primary_phone].each do |primary|
      next unless data[primary]
      list = primary == "primary_email" ? "emails" : "phones"
      errors << "#{relative}: #{primary} must also appear in #{list}" unless array(data[list]).include?(data[primary])
    end
  end

  if type == "organization"
    allowed_kinds = %w[company nonprofit government university fund community informal]
    errors << "#{relative}: invalid org_kind" unless allowed_kinds.include?(data["org_kind"])
  end

  if type == "dataset"
    identifier = /\A[a-z][a-z0-9_]{0,62}\z/
    errors << "#{relative}: dataset_slug must be a safe lowercase identifier" unless data["dataset_slug"].to_s.match?(identifier)
    errors << "#{relative}: storage_backend must be sqlite" unless data["storage_backend"] == "sqlite"
    errors << "#{relative}: storage_table must equal dataset_slug" unless data["storage_table"] == data["dataset_slug"]
    errors << "#{relative}: dataset_kind must be a safe lowercase identifier" unless data["dataset_kind"].to_s.match?(identifier)
    if data["owner"] || data["owner_id"]
      owner = resolve_link.call(relative, "owner", data["owner"])
      errors << "#{relative}: owner and owner_id must be supplied together" unless data["owner"] && data["owner_id"]
      errors << "#{relative}: owner_id does not match linked canonical entity" unless owner && owner["id"] == data["owner_id"]
    end
  end

  if type == "interaction"
    allowed_kinds = %w[meeting call email message letter encounter co_attendance]
    errors << "#{relative}: invalid interaction_kind" unless allowed_kinds.include?(data["interaction_kind"])
    errors << "#{relative}: invalid contact_weight" unless %w[substantive incidental mass].include?(data["contact_weight"])
    errors << "#{relative}: participants must contain at least two links" unless data["participants"].is_a?(Array) && data["participants"].length >= 2
  end

  if type == "introduction"
    %w[introducer person_a person_b].each do |role|
      target = resolve_link.call(relative, role, data[role])
      expected_id = data["#{role}_id"]
      errors << "#{relative}: #{role}_id does not match linked Person" unless target && target["type"] == "person" && target["id"] == expected_id
    end
    errors << "#{relative}: person_a_id must be lower than person_b_id" unless data["person_a_id"].to_s < data["person_b_id"].to_s
    errors << "#{relative}: invalid assertion_status" unless RELATIONSHIP_STATUSES.include?(data["assertion_status"])
    errors << "#{relative}: invalid confidence" unless CONFIDENCES.include?(data["confidence"])
    errors << "#{relative}: asserted_by must be human or agent" unless ACTORS.include?(data["asserted_by"])
    errors << "#{relative}: asserted_by_run required for agent assertion" if data["asserted_by"] == "agent" && !data["asserted_by_run"]
  end

  next unless type == "relationship"

  predicate = data["predicate"]
  registry = relationship_types[predicate]
  unless registry
    errors << "#{relative}: unregistered predicate #{predicate.inspect}"
    next
  end
  expected_folder = "Relationships/#{predicate}/"
  errors << "#{relative}: relationship must be stored under #{expected_folder}" unless relative.start_with?(expected_folder)
  expected_tag = "relationship/#{predicate.tr('_', '-')}"
  errors << "#{relative}: missing predicate tag #{expected_tag}" unless tags.include?(expected_tag)
  array(registry["required_fields"]).each do |field|
    errors << "#{relative}: predicate #{predicate} requires field #{field}" unless data.key?(field)
  end
  errors << "#{relative}: invalid relationship_status" unless RELATIONSHIP_STATUSES.include?(data["relationship_status"])
  errors << "#{relative}: invalid confidence" unless CONFIDENCES.include?(data["confidence"])
  errors << "#{relative}: asserted_by must be human or agent" unless ACTORS.include?(data["asserted_by"])
  errors << "#{relative}: asserted_by_run required for agent assertion" if data["asserted_by"] == "agent" && !data["asserted_by_run"]

  subject = resolve_link.call(relative, "subject", data["subject"])
  object = resolve_link.call(relative, "object", data["object"])
  errors << "#{relative}: subject_id does not match linked note" unless subject && subject["id"] == data["subject_id"]
  errors << "#{relative}: object_id does not match linked note" unless object && object["id"] == data["object_id"]
  if subject && !array(registry["subject_types"]).include?(subject["type"])
    errors << "#{relative}: #{predicate} does not allow subject type #{subject['type']}"
  end
  if object && !array(registry["object_types"]).include?(object["type"])
    errors << "#{relative}: #{predicate} does not allow object type #{object['type']}"
  end
  if registry["symmetric"] && data["subject_id"].to_s >= data["object_id"].to_s
    errors << "#{relative}: symmetric endpoints must be ordered by ID"
  end

  if data["recipient"] || data["recipient_id"]
    recipient = resolve_link.call(relative, "recipient", data["recipient"])
    errors << "#{relative}: recipient and recipient_id must be supplied together" unless data["recipient"] && data["recipient_id"]
    errors << "#{relative}: recipient_id does not match linked note" unless recipient && recipient["id"] == data["recipient_id"]
  end

  relationship_base = COMMON_REQUIRED + COMMON_OPTIONAL + %w[
    subject subject_id predicate object object_id relationship_status confidence asserted_by asserted_at
    asserted_by_run sensitivity data_origin valid_from valid_to observed_on context_links source_links source_urls
  ]
  allowed = relationship_base + array(registry["allowed_fields"])
  (data.keys - allowed).each do |field|
    errors << "#{relative}: field #{field} is not registered for predicate #{predicate}"
  end
end

active_datasets = canonical.select do |_path, _relative, data, _schema|
  data["type"] == "dataset" && data["record_status"] == "active"
end
%w[dataset_slug storage_table].each do |field|
  active_datasets.group_by { |_path, _relative, data, _schema| data[field] }.each do |value, records|
    next if value.nil? || records.length == 1

    errors << "active Dataset #{field} must be unique: #{value.inspect}"
  end
end

self_notes = canonical.count { |_p, _r, data, _s| data["type"] == "person" && data["record_status"] == "active" && data["is_self"] == true }
warnings << "No active Person has is_self: true" if self_notes.zero?
errors << "More than one active Person has is_self: true" if self_notes > 1

Dir.glob(ROOT.join("**/*.icloud").to_s).each do |path|
  errors << "#{Pathname.new(path).relative_path_from(ROOT)}: unmaterialized iCloud placeholder"
end
Dir.glob(ROOT.join("**/*conflicted copy*").to_s, File::FNM_CASEFOLD).each do |path|
  errors << "#{Pathname.new(path).relative_path_from(ROOT)}: sync conflict copy"
end

warnings.each { |warning| warn "WARN: #{warning}" }
if errors.empty?
  puts "OK: #{canonical.length} canonical notes, #{schemas.length} entity schemas, #{relationship_types.length} predicates"
  exit 0
end

errors.each { |error| warn "ERROR: #{error}" }
warn "FAILED: #{errors.length} error(s), #{warnings.length} warning(s)"
exit 1
