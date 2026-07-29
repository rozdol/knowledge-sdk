# frozen_string_literal: true

require "date"
require "digest"
require "json"

module KnowledgeIntelligence
  class RecordSnapshot
    attr_reader :id, :type, :name, :path, :data

    def initialize(id:, type:, name:, path:, data:)
      @id = id.to_s.freeze
      @type = type.to_s.freeze
      @name = name && name.to_s.freeze
      @path = path.to_s.freeze
      @data = Immutable.copy(data)
      freeze
    end

    def [](key)
      data[key.to_s]
    end

    def active?
      self["record_status"] == "active"
    end

    def to_h
      { id: id, type: type, name: name, path: path, data: data }
    end
  end

  class GraphSnapshot
    LINK = /\A\[\[([^\]|#]+)(?:#[^\]|]+)?(?:\|[^\]]+)?\]\]\z/.freeze

    attr_reader :digest, :records_by_id, :path_to_id

    def self.load(vault_root:)
      registry = KnowledgeGraph::SchemaRegistry.new(vault_root: vault_root)
      repository = KnowledgeGraph::Repository.new(vault_root: vault_root, registry: registry)
      from_repository(repository)
    end

    def self.from_repository(repository)
      records = []
      repository.each_record do |record|
        records << RecordSnapshot.new(
          id: record.id, type: record.type, name: record.data["name"],
          path: record.relative_path, data: record.data
        )
      end
      new(records)
    end

    def initialize(records)
      ordered = Array(records).sort_by(&:id)
      @records_by_id = ordered.each_with_object({}) { |record, result| result[record.id] = record }.freeze
      @path_to_id = ordered.each_with_object({}) do |record, result|
        result[record.path.sub(/\.md\z/, "")] = record.id
      end.freeze
      build_indexes(ordered)
      payload = ordered.map(&:to_h)
      @digest = Digest::SHA256.hexdigest(Stable.json(payload)).freeze
      freeze
    end

    def records(type: nil, active_only: true)
      values = type ? @records_by_type.fetch(type.to_s, []) : records_by_id.values
      values = values.select(&:active?) if active_only
      values.freeze
    end

    def record(id)
      records_by_id[id.to_s]
    end

    def fetch(id)
      records_by_id.fetch(id.to_s) { raise InvalidFeatureRequest, "unknown graph entity #{id.inspect}" }
    end

    def self_id
      person = records(type: "person").find { |record| record["is_self"] == true }
      person && person.id
    end

    def resolve_link(value)
      match = value.to_s.match(LINK)
      match && path_to_id[match[1].sub(/\.md\z/, "")]
    end

    def reference_ids(record, field)
      @reference_ids_by_field.fetch([record.id, field.to_s], [])
    end

    def records_referencing(entity_id, type: nil, fields: nil)
      allowed_fields = fields && Array(fields).map(&:to_s)
      @references_by_entity.fetch(entity_id.to_s, []).select do |record, field|
        (!type || record.type == type.to_s) && (!allowed_fields || allowed_fields.include?(field))
      end.map(&:first).uniq(&:id).sort_by(&:id).freeze
    end

    def relationships(as_of: Date.today, entity_id: nil, predicates: nil)
      allowed = predicates && Array(predicates).map(&:to_s)
      candidates = if entity_id
                     @relationships_by_entity.fetch(entity_id.to_s, [])
                   elsif allowed
                     allowed.flat_map { |predicate| @relationships_by_predicate.fetch(predicate, []) }.uniq(&:id)
                   else
                     records(type: "relationship")
                   end
      candidates.select do |record|
        next false unless record["relationship_status"] == "asserted"
        next false if allowed && !allowed.include?(record["predicate"])

        active_interval?(record, as_of)
      end.freeze
    end

    def interactions(as_of: nil, substantive_only: false)
      filter_interactions(records(type: "interaction"), as_of: as_of, substantive_only: substantive_only)
    end

    def interactions_for(entity_id, as_of: nil, substantive_only: false)
      candidates = @interactions_by_participant.fetch(entity_id.to_s, [])
      filter_interactions(candidates, as_of: as_of, substantive_only: substantive_only)
    end

    def interactions_between(first_id, second_id, as_of: nil, substantive_only: false)
      first = first_id.to_s
      second = second_id.to_s
      candidates = @interactions_by_participant.fetch(first, [])
      candidates = candidates.select { |record| @interaction_participants.fetch(record.id, []).include?(second) }
      filter_interactions(candidates, as_of: as_of, substantive_only: substantive_only)
    end

    def introductions_for(entity_id, role: nil)
      entries = @introductions_by_person.fetch(entity_id.to_s, [])
      entries = entries.select { |_record, item_role| item_role == role.to_s } if role
      entries.map(&:first).uniq(&:id).sort_by(&:id).freeze
    end

    def filter_interactions(candidates, as_of:, substantive_only:)
      candidates.select do |record|
        next false if substantive_only && record["contact_weight"] != "substantive"
        next true unless as_of

        starts = parse_time(record["starts_at"])
        starts && starts.to_date <= as_of
      end.freeze
    end

    def evidence(record, field: nil, value: nil, role: "supporting")
      Evidence.new(
        record_id: record.id, path: record.path, field: field,
        value: value.nil? && field ? record[field] : value, role: role
      )
    end

    def parse_time(value)
      case value
      when Time then value
      when DateTime then value.to_time
      when Date then Time.utc(value.year, value.month, value.day)
      else Time.parse(value.to_s)
      end
    rescue ArgumentError, TypeError
      nil
    end

    def parse_date(value, boundary: :start)
      return value if value.is_a?(Date) && !value.is_a?(DateTime)
      string = value.to_s
      case string
      when /\A\d{4}\z/
        boundary == :end ? Date.new(string.to_i, 12, 31) : Date.new(string.to_i, 1, 1)
      when /\A(\d{4})-(\d{2})\z/
        year = Regexp.last_match(1).to_i
        month = Regexp.last_match(2).to_i
        boundary == :end ? Date.new(year, month, -1) : Date.new(year, month, 1)
      else
        Date.parse(string)
      end
    rescue ArgumentError, TypeError
      nil
    end

    private

    def build_indexes(ordered)
      by_type = Hash.new { |hash, key| hash[key] = [] }
      relationships_by_entity = Hash.new { |hash, key| hash[key] = [] }
      relationships_by_predicate = Hash.new { |hash, key| hash[key] = [] }
      reference_ids_by_field = {}
      references_by_entity = Hash.new { |hash, key| hash[key] = [] }
      interactions_by_participant = Hash.new { |hash, key| hash[key] = [] }
      interaction_participants = {}
      introductions_by_person = Hash.new { |hash, key| hash[key] = [] }
      ordered.each do |record|
        by_type[record.type] << record
        record.data.each do |field, value|
          references = Array(value).map { |item| resolve_link(item) }.compact.uniq.sort
          next if references.empty?

          reference_ids_by_field[[record.id, field.to_s]] = references.freeze
          references.each { |target_id| references_by_entity[target_id] << [record, field.to_s].freeze }
        end
        if record.active? && record.type == "relationship"
          [record["subject_id"], record["object_id"]].compact.uniq.each do |entity_id|
            relationships_by_entity[entity_id] << record
          end
          relationships_by_predicate[record["predicate"]] << record
        elsif record.active? && record.type == "interaction"
          participants = reference_ids_by_field.fetch([record.id, "participants"], [])
          interaction_participants[record.id] = participants
          participants.each { |participant_id| interactions_by_participant[participant_id] << record }
        elsif record.active? && record.type == "introduction"
          { "introducer" => record["introducer_id"], "person_a" => record["person_a_id"],
            "person_b" => record["person_b_id"] }.each do |role, person_id|
            introductions_by_person[person_id] << [record, role].freeze if person_id
          end
        end
      end
      @records_by_type = freeze_array_index(by_type)
      @relationships_by_entity = freeze_array_index(relationships_by_entity)
      @relationships_by_predicate = freeze_array_index(relationships_by_predicate)
      @reference_ids_by_field = reference_ids_by_field.freeze
      @references_by_entity = freeze_array_index(references_by_entity)
      @interactions_by_participant = freeze_array_index(interactions_by_participant)
      @interaction_participants = interaction_participants.freeze
      @introductions_by_person = freeze_array_index(introductions_by_person)
    end

    def freeze_array_index(index)
      index.each_with_object({}) do |(key, values), result|
        result[key.to_s.freeze] = values.freeze
      end.freeze
    end

    def active_interval?(record, as_of)
      starts = parse_date(record["valid_from"], boundary: :start) if record["valid_from"]
      ends = parse_date(record["valid_to"], boundary: :end) if record["valid_to"]
      (!starts || starts <= as_of) && (!ends || ends >= as_of)
    end
  end
end
