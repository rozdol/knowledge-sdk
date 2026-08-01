#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "open3"
require "tmpdir"

source_root = File.expand_path("..", __dir__)
plugin_root = File.join(source_root, "plugins/personal-crm")
validator = File.join(source_root, "validators/personal_crm/validate_vault.rb")

def write(path, content)
  FileUtils.mkdir_p(File.dirname(path))
  File.write(path, content)
end

Dir.mktmpdir("knowledge-graph-validator-") do |root|
  FileUtils.mkdir_p(File.join(root, "_System"))
  FileUtils.mkdir_p(File.join(root, "_System/Schema"))
  FileUtils.cp_r(File.join(plugin_root, "schemas"), File.join(root, "_System/Schema/Entity Types"))
  FileUtils.cp_r(File.join(plugin_root, "relationship_types"), File.join(root, "_System/Relationship Types"))

  write(File.join(root, "People/Alice.md"), <<~MARKDOWN)
    ---
    id: person_01K1D9VB96W7CS7F4M7K8Q2Z0A
    type: person
    schema_version: 1
    name: Alice
    aliases: []
    record_status: active
    created_at: 2026-07-29T10:00:00+03:00
    updated_at: 2026-07-29T10:00:00+03:00
    created_by: human
    updated_by: human
    tags: [entity/person]
    tier: active
    sensitivity: private
    data_origin: given_by_subject
    is_self: true
    ---
    # Alice
  MARKDOWN

  write(File.join(root, "Concepts/Interests/Skiing.md"), <<~MARKDOWN)
    ---
    id: interest_01K1DCC8Q6V4R5T7S2NXB8K4QW
    type: interest
    schema_version: 1
    name: Skiing
    aliases: []
    record_status: active
    created_at: 2026-07-29T10:00:00+03:00
    updated_at: 2026-07-29T10:00:00+03:00
    created_by: human
    updated_by: human
    tags: [entity/interest]
    interest_kind: sport
    ---
    # Skiing
  MARKDOWN

  relationship_path = File.join(root, "Relationships/likes/relationship_01K1DEG5AB7ZQ9H4N2VCR8Q4ZM.md")
  valid_relationship = <<~MARKDOWN
    ---
    id: relationship_01K1DEG5AB7ZQ9H4N2VCR8Q4ZM
    type: relationship
    schema_version: 1
    record_status: active
    created_at: 2026-07-29T10:00:00+03:00
    updated_at: 2026-07-29T10:00:00+03:00
    created_by: human
    updated_by: human
    tags: [entity/relationship, relationship/likes]
    subject: "[[People/Alice|Alice]]"
    subject_id: person_01K1D9VB96W7CS7F4M7K8Q2Z0A
    predicate: likes
    object: "[[Concepts/Interests/Skiing|Skiing]]"
    object_id: interest_01K1DCC8Q6V4R5T7S2NXB8K4QW
    relationship_status: asserted
    confidence: confirmed
    asserted_by: human
    asserted_at: 2026-07-29T10:00:00+03:00
    sensitivity: private
    data_origin: given_by_subject
    ---
  MARKDOWN
  write(relationship_path, valid_relationship)

  stdout, stderr, status = Open3.capture3({ "VAULT_ROOT" => root }, "ruby", validator)
  abort "valid fixture failed:\n#{stdout}#{stderr}" unless status.success?

  write(relationship_path, valid_relationship.sub(
    "object_id: interest_01K1DCC8Q6V4R5T7S2NXB8K4QW",
    "object_id: interest_01K1DCC8Q6V4R5T7S2NX000000"
  ))
  _stdout, stderr, status = Open3.capture3({ "VAULT_ROOT" => root }, "ruby", validator)
  abort "invalid fixture unexpectedly passed" if status.success?
  abort "mismatch error was not reported" unless stderr.include?("object_id does not match linked note")
end

puts "OK: validator accepts valid data and rejects an ID/link mismatch"
