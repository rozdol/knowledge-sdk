# frozen_string_literal: true

require "set"
require "time"

module KnowledgeGraph
  class EntityManager
    APPROVAL_GATED_TYPES = Set.new(%w[interest technology industry profession language]).freeze
    IMMUTABLE_FIELDS = Set.new(%w[
      id type schema_version record_status merged_into created_at updated_at created_by updated_by
      created_by_run updated_by_run
    ]).freeze
    DERIVED_FIELDS = Set.new(%w[last_contacted current_organization age relationship_count interaction_count]).freeze

    def initialize(vault_root:, registry:, writer:, id_generator:, clock:, run_id:)
      @vault_root = Pathname.new(vault_root)
      @registry = registry
      @writer = writer
      @id_generator = id_generator
      @clock = clock
      @run_id = run_id
    end

    def create(intent, context)
      schema = @registry.fetch(intent.entity_type)
      if APPROVAL_GATED_TYPES.include?(schema.key) && !intent.human_approved
        raise ApprovalRequired, "creating #{schema.key} requires explicit human approval"
      end
      attributes = stringify(intent.attributes)
      now = timestamp
      entity_id = attributes.delete("id") || @id_generator.generate(schema.id_prefix)
      data = attributes.merge(
        "id" => entity_id,
        "type" => schema.key,
        "schema_version" => 1,
        "record_status" => "active",
        "created_at" => now,
        "updated_at" => now,
        "created_by" => "agent",
        "updated_by" => "agent",
        "created_by_run" => @run_id,
        "updated_by_run" => @run_id,
        "tags" => (schema.required_tags + Array(attributes["tags"])).uniq
      )
      data["aliases"] = [] if schema.name_required? && !data.key?("aliases")
      reject_derived!(data.keys)
      relative_path = new_path(schema, data, entity_id)
      raise EntityConflict, "path already exists: #{relative_path}" if context.transaction.exist?(relative_path)

      body = intent.body.nil? ? default_body(schema, data) : intent.body
      context.transaction.write(relative_path, @writer.render(data, body: body))
      result(intent, [entity_id], relative_path: relative_path)
    end

    def update(intent, context)
      record = repository.resolve(intent.entity_id)
      changes = stringify(intent.changes)
      reject_fields!(changes.keys, IMMUTABLE_FIELDS)
      raise InvalidIntent, "use RenameEntity to change name" if changes.key?("name")
      reject_derived!(changes.keys)
      data = record.data.merge(changes)
      stamp_update!(data)
      write_record(context, record, data)
      result(intent, [record.id], relative_path: record.relative_path)
    end

    def rename(intent, context)
      record = repository.resolve(intent.entity_id)
      schema = @registry.fetch(record.type)
      raise InvalidIntent, "#{record.type} records do not have names" unless schema.name_required?

      data = record.data.dup
      old_name = data.fetch("name")
      data["name"] = intent.new_name.to_s
      data["aliases"] = (Array(data["aliases"]) + [old_name]).reject { |name| name == data["name"] }.uniq
      stamp_update!(data)
      destination = unique_named_path(schema, data["name"], record.id, excluding: record.relative_path)
      rendered = @writer.render(data, body: record.body)
      context.transaction.write(destination, rendered)
      context.transaction.delete(record.relative_path) unless destination == record.relative_path
      rewrite_backlinks(context, record.relative_path, destination)
      result(intent, [record.id], relative_path: destination)
    end

    def archive(intent, context)
      change_status(intent, context, "archived")
    end

    def restore(intent, context)
      change_status(intent, context, "active")
    end

    def attach_evidence(intent, context)
      record = repository.resolve(intent.entity_id)
      data = record.data.dup
      data["source_links"] = (Array(data["source_links"]) + intent.source_links).uniq unless intent.source_links.empty?
      data["source_urls"] = (Array(data["source_urls"]) + intent.source_urls).uniq unless intent.source_urls.empty?
      stamp_update!(data)
      write_record(context, record, data)
      result(intent, [record.id], relative_path: record.relative_path)
    end

    def import_transcript(intent, context)
      record = repository.resolve(intent.interaction_id)
      raise InvalidIntent, "transcripts can only be attached to interactions" unless record.type == "interaction"

      body = replace_managed_section(record.body, "transcript", intent.transcript)
      data = record.data.dup
      stamp_update!(data)
      context.transaction.write(record.relative_path, @writer.render(data, body: body))
      result(intent, [record.id], relative_path: record.relative_path)
    end

    def complete_follow_up(intent, context)
      record = repository.resolve(intent.follow_up_id)
      raise InvalidIntent, "CompleteFollowUp requires a follow-up" unless record.type == "follow-up"

      data = record.data.merge(
        "followup_status" => "completed",
        "completed_on" => intent.completed_on || @clock.call.strftime("%Y-%m-%d")
      )
      stamp_update!(data)
      write_record(context, record, data)
      result(intent, [record.id], relative_path: record.relative_path)
    end

    def create_meeting(intent, context)
      attributes = stringify(intent.attributes)
      attributes["interaction_kind"] ||= "meeting"
      attributes["contact_weight"] ||= "substantive"
      create_special(intent, context, "interaction", attributes)
    end

    def record_interaction(intent, context)
      create_special(intent, context, "interaction", stringify(intent.attributes))
    end

    def record_promise(intent, context)
      attributes = stringify(intent.attributes)
      attributes["commitment_kind"] ||= "promise"
      attributes["commitment_status"] ||= "open"
      create_special(intent, context, "commitment", attributes)
    end

    private

    def repository
      Repository.new(vault_root: @vault_root, registry: @registry)
    end

    def stringify(hash)
      hash.each_with_object({}) { |(key, value), result| result[key.to_s] = value }
    end

    def timestamp
      @clock.call.iso8601
    end

    def stamp_update!(data)
      data["updated_at"] = timestamp
      data["updated_by"] = "agent"
      data["updated_by_run"] = @run_id
    end

    def reject_fields!(fields, forbidden)
      invalid = fields & forbidden.to_a
      raise InvalidIntent, "immutable fields cannot be changed: #{invalid.join(', ')}" unless invalid.empty?
    end

    def reject_derived!(fields)
      invalid = fields & DERIVED_FIELDS.to_a
      raise InvalidIntent, "derived fields cannot be persisted: #{invalid.join(', ')}" unless invalid.empty?
    end

    def write_record(context, record, data)
      context.transaction.write(record.relative_path, @writer.render(data, body: record.body))
    end

    def change_status(intent, context, status)
      record = repository.resolve(intent.entity_id)
      return result(intent, [record.id], relative_path: record.relative_path, replayed: true) if record.data["record_status"] == status

      data = record.data.merge("record_status" => status)
      data.delete("merged_into") if status == "active"
      stamp_update!(data)
      write_record(context, record, data)
      result(intent, [record.id], relative_path: record.relative_path)
    end

    def result(intent, entity_ids, relative_path:, replayed: false)
      Result.new(
        intent_type: intent.intent_type,
        entity_ids: entity_ids,
        value: { relative_path: relative_path }.freeze,
        replayed: replayed
      )
    end

    def default_body(schema, data)
      schema.name_required? ? "# #{data.fetch('name')}\n" : ""
    end

    def new_path(schema, data, entity_id)
      if schema.id_filename?
        File.join(schema.folder_prefixes.first, "#{entity_id}.md")
      else
        folder = entity_folder(schema, data)
        name = dated_name(schema, data, data.fetch("name"))
        unique_named_path(schema, name, entity_id, folder: folder)
      end
    end

    def unique_named_path(schema, name, entity_id, excluding: nil, folder: nil)
      folder ||= schema.folder_prefixes.first
      base = safe_filename(name)
      first = File.join(folder, "#{base}.md")
      return first if first == excluding || !@vault_root.join(first).exist?

      File.join(folder, "#{base} - #{entity_id[-6, 6]}.md")
    end

    def entity_folder(schema, data)
      return schema.folder_prefixes.first unless schema.key == "interaction"

      case data["interaction_kind"]
      when "meeting" then "Interactions/Meetings/"
      when "call" then "Interactions/Calls/"
      when "email", "message", "letter" then "Interactions/Messages/"
      else "Interactions/Other/"
      end
    end

    def dated_name(schema, data, name)
      return name unless %w[interaction event].include?(schema.key)

      date = data["starts_at"].to_s[0, 10]
      date.match?(/\A\d{4}-\d{2}-\d{2}\z/) && !name.start_with?(date) ? "#{date} - #{name}" : name
    end

    def create_special(original_intent, context, entity_type, attributes)
      created = create(
        CreateEntity.new(
          entity_type: entity_type,
          attributes: attributes,
          body: original_intent.body,
          intent_id: original_intent.intent_id
        ),
        context
      )
      Result.new(
        intent_type: original_intent.intent_type,
        entity_ids: created.entity_ids,
        value: created.value,
        replayed: created.replayed
      )
    end

    def safe_filename(value)
      cleaned = value.to_s.gsub(/[\\\/:|#^\[\]]/, "-").gsub(/\s+/, " ").strip[0, 100]
      cleaned.empty? ? "Untitled" : cleaned
    end

    def rewrite_backlinks(context, source, destination)
      old_target = source.sub(/\.md\z/, "")
      new_target = destination.sub(/\.md\z/, "")
      repository.markdown_paths.each do |relative|
        next if relative == source

        content = context.transaction.read(relative)
        next unless content

        content = content.dup.force_encoding(Encoding::UTF_8) if content.encoding == Encoding::ASCII_8BIT
        updated = content.gsub(/\[\[#{Regexp.escape(old_target)}(?=[#|\]])/, "[[#{new_target}")
                         .gsub(/\[\[#{Regexp.escape(old_target)}\.md(?=[#|\]])/, "[[#{new_target}")
        context.transaction.write(relative, updated) unless updated == content
      end
    end

    def replace_managed_section(body, key, content)
      opening = "<!-- BEGIN AGENT-MANAGED: #{key} -->"
      closing = "<!-- END AGENT-MANAGED: #{key} -->"
      section = "#{opening}\n#{content.to_s.rstrip}\n#{closing}"
      pattern = /#{Regexp.escape(opening)}.*?#{Regexp.escape(closing)}/m
      return body.sub(pattern, section) if body.match?(pattern)

      [body.rstrip, section, ""].join("\n\n")
    end
  end
end
