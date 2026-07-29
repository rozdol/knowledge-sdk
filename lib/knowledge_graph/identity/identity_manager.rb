# frozen_string_literal: true

require "set"
require "time"

module KnowledgeGraph
  class IdentityManager
    SYSTEM_FIELDS = Set.new(%w[
      id type schema_version record_status merged_into created_at updated_at created_by updated_by
      created_by_run updated_by_run
    ]).freeze
    UNION_FIELDS = Set.new(%w[
      aliases former_names nicknames transliterations emails phones external_ids domains source_links source_urls tags
    ]).freeze
    PRIMARY_WINS = Set.new(%w[primary_email primary_phone tier]).freeze
    SENSITIVITY = { "normal" => 0, "private" => 1, "restricted" => 2 }.freeze

    def initialize(vault_root:, schema_registry:, relationship_registry:, entity_manager:, writer:, clock:, run_id:)
      @vault_root = Pathname.new(vault_root)
      @schema_registry = schema_registry
      @relationship_registry = relationship_registry
      @entity_manager = entity_manager
      @writer = writer
      @clock = clock
      @run_id = run_id
    end

    def merge(intent, context)
      repo = repository
      primary = repo.resolve(intent.primary_id)
      secondary = repo.find(intent.secondary_id)
      if secondary.data["record_status"] == "merged"
        resolved = repo.resolve(secondary.id)
        return merge_result(intent, primary, secondary, replayed: true) if resolved.id == primary.id

        raise IdentityConflict, "secondary already redirects to #{resolved.id}"
      end
      raise IdentityConflict, "cannot merge an entity into itself" if primary.id == secondary.id
      raise IdentityConflict, "entity types differ: #{primary.type} and #{secondary.type}" if primary.type != secondary.type
      require_approval!(primary.type, intent.human_approved, "merge")

      transformed = transform_records(repo, primary, secondary)
      deduplicate_relationships!(transformed)
      transformed.each_value do |entry|
        context.transaction.write(
          entry.fetch(:record).relative_path,
          @writer.render(entry.fetch(:data), body: entry.fetch(:body))
        )
      end
      rewrite_noncanonical_links(repo, context, secondary.relative_path, primary.relative_path, transformed.keys)
      merge_result(intent, primary, secondary, replayed: false)
    end

    def split(intent, context)
      record = repository.find(intent.entity_id)
      require_approval!(record.type, intent.human_approved, "split") if approval_gated?(record.type)
      if record.data["record_status"] == "merged"
        data = record.data.merge(stringify(intent.attributes))
        data["record_status"] = "active"
        data.delete("merged_into")
        stamp!(data)
        body = intent.body.nil? ? record.body : intent.body
        context.transaction.write(record.relative_path, @writer.render(data, body: body))
        return Result.new(
          intent_type: intent.intent_type,
          entity_ids: [record.id],
          value: { relative_path: record.relative_path }.freeze
        )
      end

      created = @entity_manager.create(
        CreateEntity.new(
          entity_type: record.type,
          attributes: intent.attributes,
          body: intent.body,
          human_approved: intent.human_approved,
          intent_id: intent.intent_id
        ),
        context
      )
      Result.new(
        intent_type: intent.intent_type,
        entity_ids: created.entity_ids,
        value: created.value,
        replayed: created.replayed
      )
    end

    private

    def repository
      Repository.new(vault_root: @vault_root, registry: @schema_registry)
    end

    def transform_records(repo, primary, secondary)
      transformed = {}
      repo.each_record do |record|
        data = deep_copy(record.data)
        body = rewrite_link_target(record.body, secondary.relative_path, primary.relative_path)
        changed = rewrite_references!(data, secondary, primary)

        if record.id == primary.id
          data = merge_data(primary.data, secondary.data)
          rewrite_references!(data, secondary, primary)
          stamp!(data)
          changed = true
        elsif record.id == secondary.id
          data["record_status"] = "merged"
          data["merged_into"] = primary.link
          stamp!(data)
          changed = true
        end

        normalize_roles!(record, data) if changed
        transformed[record.id] = { record: record, data: data, body: body } if changed || body != record.body
      end
      transformed
    end

    def merge_data(primary, secondary)
      data = deep_copy(primary)
      data["aliases"] = union(Array(data["aliases"]), [secondary["name"]], Array(secondary["aliases"]))
      secondary.each do |key, value|
        next if SYSTEM_FIELDS.include?(key) || key == "name" || value.nil?

        if UNION_FIELDS.include?(key) || value.is_a?(Array)
          data[key] = union(Array(data[key]), Array(value))
        elsif !data.key?(key)
          data[key] = value
        elsif data[key] == value
          next
        elsif key == "sensitivity"
          data[key] = [data[key], value].max_by { |item| SENSITIVITY.fetch(item, 1) }
        elsif key == "data_origin"
          data[key] = "mixed"
        elsif key == "contact_policy"
          data[key] = "do_not_contact" if value == "do_not_contact"
        elsif key == "is_self"
          data[key] = !!data[key] || !!value
        elsif PRIMARY_WINS.include?(key)
          next
        else
          raise IdentityConflict, "conflicting field #{key}: #{data[key].inspect} vs #{value.inspect}"
        end
      end
      data
    end

    def rewrite_references!(data, secondary, primary)
      changed = false
      data.each do |key, value|
        replacement = if value.is_a?(Array)
                        value.map { |item| rewrite_link_target(item, secondary.relative_path, primary.relative_path) }
                      else
                        rewrite_link_target(value, secondary.relative_path, primary.relative_path)
                      end
        if key.end_with?("_id") && replacement == secondary.id
          replacement = primary.id
        end
        next if replacement == value

        data[key] = replacement
        changed = true
      end
      changed
    end

    def rewrite_link_target(value, old_path, new_path)
      return value unless value.is_a?(String)

      old_target = old_path.sub(/\.md\z/, "")
      new_target = new_path.sub(/\.md\z/, "")
      value.gsub(/\[\[#{Regexp.escape(old_target)}(?=[#|\]])/, "[[#{new_target}")
           .gsub(/\[\[#{Regexp.escape(old_target)}\.md(?=[#|\]])/, "[[#{new_target}")
    end

    def normalize_roles!(record, data)
      if record.type == "relationship"
        definition = @relationship_registry.fetch(data.fetch("predicate"))
        if definition.symmetric? && data["subject_id"] == data["object_id"]
          raise IdentityConflict, "merge would create self-relationship #{record.id}"
        end
        if definition.symmetric? && data["subject_id"] > data["object_id"]
          data["subject"], data["object"] = data["object"], data["subject"]
          data["subject_id"], data["object_id"] = data["object_id"], data["subject_id"]
        end
      elsif record.type == "introduction" && data["person_a_id"] == data["person_b_id"]
        raise IdentityConflict, "merge would collapse Introduction roles in #{record.id}"
      elsif record.type == "introduction" && data["person_a_id"] > data["person_b_id"]
        data["person_a"], data["person_b"] = data["person_b"], data["person_a"]
        data["person_a_id"], data["person_b_id"] = data["person_b_id"], data["person_a_id"]
      end
    end

    def deduplicate_relationships!(transformed)
      entries = repository_records_with_transforms(transformed).select do |entry|
        entry.fetch(:record).type == "relationship" && entry.fetch(:data)["relationship_status"] == "asserted"
      end
      grouped = entries.group_by { |entry| relationship_signature(entry.fetch(:data)) }
      grouped.each_value do |duplicates|
        next if duplicates.length < 2

        duplicates.sort_by { |entry| entry.fetch(:record).id }[1..-1].each do |duplicate|
          record = duplicate.fetch(:record)
          entry = transformed[record.id] ||= {
            record: record, data: deep_copy(record.data), body: record.body
          }
          entry.fetch(:data)["relationship_status"] = "retracted"
          stamp!(entry.fetch(:data))
        end
      end
    end

    def repository_records_with_transforms(transformed)
      repository.each_record.map do |record|
        transformed[record.id] || { record: record, data: record.data, body: record.body }
      end
    end

    def relationship_signature(data)
      [
        data["subject_id"], data["predicate"], data["object_id"], data["recipient_id"],
        data["valid_from"], data["valid_to"], Array(data["context_links"])
      ]
    end

    def rewrite_noncanonical_links(repo, context, old_path, new_path, canonical_ids)
      canonical_paths = repo.each_record.to_a.select { |record| canonical_ids.include?(record.id) }
                            .map(&:relative_path).to_set
      repo.markdown_paths.each do |relative|
        next if canonical_paths.include?(relative)

        content = context.transaction.read(relative)
        updated = rewrite_link_target(content, old_path, new_path)
        context.transaction.write(relative, updated) unless updated == content
      end
    end

    def require_approval!(type, approved, operation)
      gated = type == "person" || (operation == "split" && EntityManager::APPROVAL_GATED_TYPES.include?(type))
      return unless gated && !approved

      raise ApprovalRequired, "#{type} #{operation} requires explicit human approval"
    end

    def approval_gated?(type)
      type == "person" || EntityManager::APPROVAL_GATED_TYPES.include?(type)
    end

    def stamp!(data)
      data["updated_at"] = @clock.call.iso8601
      data["updated_by"] = "agent"
      data["updated_by_run"] = @run_id
    end

    def stringify(hash)
      hash.each_with_object({}) { |(key, value), result| result[key.to_s] = value }
    end

    def union(*lists)
      lists.flatten.compact.each_with_object([]) { |item, result| result << item unless result.include?(item) }
    end

    def deep_copy(value)
      case value
      when Hash then value.each_with_object({}) { |(key, item), result| result[key] = deep_copy(item) }
      when Array then value.map { |item| deep_copy(item) }
      else value
      end
    end

    def merge_result(intent, primary, secondary, replayed:)
      Result.new(
        intent_type: intent.intent_type,
        entity_ids: [primary.id, secondary.id],
        value: { primary_id: primary.id, secondary_id: secondary.id }.freeze,
        replayed: replayed
      )
    end
  end
end
