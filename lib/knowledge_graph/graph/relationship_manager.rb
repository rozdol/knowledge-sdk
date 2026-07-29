# frozen_string_literal: true

require "set"
require "time"

module KnowledgeGraph
  class RelationshipManager
    OPTIONAL_FIELDS = Set.new(%w[
      confidence sensitivity data_origin valid_from valid_to observed_on context_links source_links source_urls
    ]).freeze
    RESERVED_FIELDS = Set.new(%w[
      id type schema_version record_status created_at updated_at created_by updated_by created_by_run
      updated_by_run tags subject subject_id predicate object object_id relationship_status asserted_by
      asserted_at asserted_by_run
    ]).freeze

    def initialize(vault_root:, schema_registry:, relationship_registry:, writer:, id_generator:, clock:, run_id:)
      @vault_root = Pathname.new(vault_root)
      @schema_registry = schema_registry
      @relationship_registry = relationship_registry
      @writer = writer
      @id_generator = id_generator
      @clock = clock
      @run_id = run_id
    end

    def add(intent, context)
      created = create_relationship(intent, context)
      relationship_result(intent, [created.fetch(:id)], created.fetch(:path), replayed: created.fetch(:replayed))
    end

    def remove(intent, context)
      record = repository.find(intent.relationship_id)
      ensure_relationship!(record)
      replayed = retract(record, context)
      relationship_result(intent, [record.id], record.relative_path, replayed: replayed)
    end

    def replace(intent, context)
      old_record = repository.find(intent.relationship_id)
      ensure_relationship!(old_record)
      old_replayed = retract(old_record, context)
      created = create_relationship(intent, context, ignore_ids: [old_record.id])
      relationship_result(
        intent,
        [old_record.id, created.fetch(:id)].uniq,
        created.fetch(:path),
        replayed: old_replayed && created.fetch(:replayed)
      )
    end

    private

    def create_relationship(intent, context, ignore_ids: [])
      definition = @relationship_registry.fetch(intent.predicate)
      source = repository.resolve(intent.source)
      target = repository.resolve(intent.target)
      source, target = canonical_endpoints(source, target, definition)
      validate_endpoint_types!(source, target, definition)
      attributes = normalize_attributes(intent.attributes, definition)
      existing = find_existing(source.id, target.id, definition.predicate, ignore_ids)
      if existing
        supplied = attributes.all? { |key, value| existing.data[key] == value }
        unless supplied
          raise RelationshipConflict,
                "relationship #{existing.id} already exists; use ReplaceRelationship to change attributes"
        end
        return { id: existing.id, path: existing.relative_path, replayed: true }
      end

      now = timestamp
      relationship_id = @id_generator.generate("relationship")
      data = attributes.merge(
        "id" => relationship_id,
        "type" => "relationship",
        "schema_version" => 1,
        "record_status" => "active",
        "created_at" => now,
        "updated_at" => now,
        "created_by" => "agent",
        "updated_by" => "agent",
        "created_by_run" => @run_id,
        "updated_by_run" => @run_id,
        "tags" => ["entity/relationship", "relationship/#{definition.predicate.tr('_', '-')}"],
        "subject" => source.link,
        "subject_id" => source.id,
        "predicate" => definition.predicate,
        "object" => target.link,
        "object_id" => target.id,
        "relationship_status" => "asserted",
        "confidence" => attributes.fetch("confidence", "confirmed"),
        "asserted_by" => "agent",
        "asserted_at" => now,
        "asserted_by_run" => @run_id,
        "sensitivity" => attributes.fetch("sensitivity", conservative_sensitivity(source, target)),
        "data_origin" => attributes.fetch("data_origin", "inferred")
      )
      resolve_recipient!(data, definition)
      missing = definition.required_fields.reject { |field| data.key?(field) }
      unless missing.empty?
        raise RelationshipConflict, "#{definition.predicate} requires: #{missing.join(', ')}"
      end

      relative_path = "Relationships/#{definition.predicate}/#{relationship_id}.md"
      context.transaction.write(relative_path, @writer.render(data))
      { id: relationship_id, path: relative_path, replayed: false }
    end

    def repository
      Repository.new(vault_root: @vault_root, registry: @schema_registry)
    end

    def normalize_attributes(input, definition)
      attributes = input.each_with_object({}) { |(key, value), result| result[key.to_s] = value }
      reserved = attributes.keys & RESERVED_FIELDS.to_a
      raise InvalidIntent, "reserved relationship fields: #{reserved.join(', ')}" unless reserved.empty?

      allowed = OPTIONAL_FIELDS | Set.new(definition.allowed_fields)
      unknown = attributes.keys.reject { |field| allowed.include?(field) }
      raise RelationshipConflict, "fields not allowed for #{definition.predicate}: #{unknown.join(', ')}" unless unknown.empty?

      attributes
    end

    def canonical_endpoints(source, target, definition)
      return [source, target] unless definition.symmetric? && source.id > target.id

      [target, source]
    end

    def validate_endpoint_types!(source, target, definition)
      unless definition.subject_types.include?(source.type)
        raise RelationshipConflict,
              "#{definition.predicate} does not allow subject type #{source.type}"
      end
      unless definition.object_types.include?(target.type)
        raise RelationshipConflict,
              "#{definition.predicate} does not allow object type #{target.type}"
      end
      if definition.symmetric? && source.id == target.id
        raise RelationshipConflict, "symmetric relationship endpoints must be distinct"
      end
    end

    def find_existing(subject_id, object_id, predicate, ignore_ids)
      repository.each_record.find do |record|
        record.type == "relationship" && !ignore_ids.include?(record.id) &&
          record.data["relationship_status"] == "asserted" &&
          record.data["subject_id"] == subject_id && record.data["object_id"] == object_id &&
          record.data["predicate"] == predicate
      end
    end

    def resolve_recipient!(data, definition)
      return unless definition.predicate == "recommended"

      recipient_reference = data.delete("recipient_id") || data.delete("recipient")
      return unless recipient_reference

      recipient = repository.resolve(recipient_reference)
      data["recipient"] = recipient.link
      data["recipient_id"] = recipient.id
    end

    def retract(record, context)
      return true if record.data["relationship_status"] == "retracted"

      data = record.data.merge(
        "relationship_status" => "retracted",
        "updated_at" => timestamp,
        "updated_by" => "agent",
        "updated_by_run" => @run_id
      )
      context.transaction.write(record.relative_path, @writer.render(data, body: record.body))
      false
    end

    def ensure_relationship!(record)
      raise InvalidIntent, "expected relationship, got #{record.type}" unless record.type == "relationship"
    end

    def conservative_sensitivity(source, target)
      levels = { "normal" => 0, "private" => 1, "restricted" => 2 }
      values = [source.data["sensitivity"], target.data["sensitivity"]].compact
      values.max_by { |value| levels.fetch(value, 1) } || "private"
    end

    def timestamp
      @clock.call.iso8601
    end

    def relationship_result(intent, ids, path, replayed:)
      Result.new(
        intent_type: intent.intent_type,
        entity_ids: ids,
        value: { relative_path: path }.freeze,
        replayed: replayed
      )
    end
  end
end
