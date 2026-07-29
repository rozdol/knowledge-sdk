# frozen_string_literal: true

module KnowledgeGraph
  class EntitySnapshot
    attr_reader :id, :type, :name, :aliases, :emails, :phones, :external_ids,
                :domains, :sensitivity, :record_status, :relative_path, :link, :attributes

    def initialize(record)
      data = record.data
      @id = record.id.to_s.freeze
      @type = record.type.to_s.freeze
      @name = data["name"]&.to_s&.freeze
      @aliases = Array(data["aliases"]).map { |item| item.to_s.freeze }.freeze
      @emails = Array(data["emails"]).map { |item| item.to_s.freeze }.freeze
      @phones = Array(data["phones"]).map { |item| item.to_s.freeze }.freeze
      @external_ids = Array(data["external_ids"]).map { |item| item.to_s.freeze }.freeze
      @domains = Array(data["domains"]).map { |item| item.to_s.freeze }.freeze
      @sensitivity = data["sensitivity"]&.to_s&.freeze
      @record_status = data["record_status"].to_s.freeze
      @relative_path = record.relative_path.to_s.freeze
      @link = record.link.freeze
      @attributes = {
        "legal_name" => data["legal_name"], "role" => data["role"],
        "org_kind" => data["org_kind"], "website" => data["website"],
        "is_self" => data["is_self"]
      }.reject { |_key, value| value.nil? }.freeze
      freeze
    end

    def to_h
      {
        id: id, type: type, name: name, aliases: aliases, emails: emails, phones: phones,
        external_ids: external_ids, domains: domains, sensitivity: sensitivity,
        record_status: record_status, relative_path: relative_path, link: link,
        attributes: attributes
      }
    end
  end

  class GraphReader
    def initialize(vault_root:)
      @schema_registry = SchemaRegistry.new(vault_root: vault_root)
      @relationship_registry = RelationshipRegistry.new(vault_root: vault_root)
      @repository = Repository.new(vault_root: vault_root, registry: @schema_registry)
      @identity_resolver = IdentityResolver.new(repository: @repository)
    end

    def entity_types
      @schema_registry.keys.sort.freeze
    end

    def predicates
      @relationship_registry.predicates.sort.freeze
    end

    def search(query, entity_type: nil, strong_only: false)
      @identity_resolver.search(query, entity_type: entity_type, strong_only: strong_only).map do |match|
        { entity: EntitySnapshot.new(match.record), signals: match.signals.map(&:to_s).sort.freeze }.freeze
      end.freeze
    end

    def find(entity_id)
      EntitySnapshot.new(@repository.resolve(entity_id))
    end

    def self_entity
      record = nil
      @repository.each_record do |candidate|
        if candidate.type == "person" && candidate.data["record_status"] == "active" && candidate.data["is_self"] == true
          record = candidate
          break
        end
      end
      record && EntitySnapshot.new(record)
    end

    def predicate(predicate)
      definition = @relationship_registry.fetch(predicate)
      {
        predicate: definition.predicate, subject_types: definition.subject_types,
        object_types: definition.object_types, inverse: definition.inverse,
        allowed_fields: definition.allowed_fields, required_fields: definition.required_fields,
        symmetric: definition.symmetric?
      }.freeze
    end

    def relationship_exists?(source_id:, predicate:, target_id:)
      definition = @relationship_registry.fetch(predicate)
      source, target = if definition.symmetric? && source_id.to_s > target_id.to_s
                         [target_id.to_s, source_id.to_s]
                       else
                         [source_id.to_s, target_id.to_s]
                       end
      found = false
      @repository.each_record do |record|
        data = record.data
        next unless record.type == "relationship" && data["relationship_status"] == "asserted"

        if data["subject_id"] == source && data["predicate"] == predicate.to_s && data["object_id"] == target
          found = true
          break
        end
      end
      found
    end
  end
end
