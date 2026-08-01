# frozen_string_literal: true

require "set"
require "uri"

module KnowledgeGraph
  IdentityMatch = Struct.new(:record, :signals, keyword_init: true)

  class IdentityResolver
    NAME_FIELDS = %w[name legal_name aliases former_names nicknames transliterations].freeze
    STRONG_FIELDS = {
      "emails" => :email,
      "phones" => :phone,
      "external_ids" => :external_id,
      "domains" => :domain,
      "isbn" => :isbn,
      "iso_alpha2" => :iso_code
    }.freeze

    def initialize(repository:)
      @repository = repository
    end

    def resolve(reference)
      if reference.to_s.match?(/\A[a-z][a-z0-9-]*_[0-9A-HJKMNP-TV-Z]{26}\z/)
        return @repository.resolve(reference)
      end

      matches = search(reference, strong_only: true)
      raise EntityNotFound, "identity not found: #{reference}" if matches.empty?
      if matches.length > 1
        raise IdentityConflict, "identity reference is ambiguous: #{reference}"
      end

      @repository.resolve(matches.first.record.id)
    end

    def search(reference, entity_type: nil, strong_only: false)
      query = reference.to_s
      matches = []
      @repository.each_record do |record|
        next if entity_type && record.type != entity_type.to_s

        signals = matching_signals(record, query, strong_only)
        matches << IdentityMatch.new(record: record, signals: signals.freeze).freeze unless signals.empty?
      end
      collapse_redirects(matches)
    end

    def duplicate_candidates(entity_id)
      source = @repository.find(entity_id)
      candidates = {}
      strong_values(source).each do |kind, value|
        search(value, entity_type: source.type, strong_only: true).each do |match|
          next if match.record.id == source.id

          entry = candidates[match.record.id] ||= { record: match.record, signals: Set.new }
          entry[:signals] << kind
        end
      end
      candidates.values.map do |entry|
        IdentityMatch.new(record: entry.fetch(:record), signals: entry.fetch(:signals).to_a.sort.freeze).freeze
      end
    end

    private

    def matching_signals(record, query, strong_only)
      signals = []
      strong_values(record).each do |kind, value|
        signals << kind if normalize(kind, value) == normalize(kind, query)
      end
      return signals.uniq if strong_only

      NAME_FIELDS.each do |field|
        Array(record.data[field]).each do |value|
          signals << :name if normalize(:name, value) == normalize(:name, query)
        end
      end
      signals.uniq
    end

    def strong_values(record)
      values = [[:id, record.id]]
      STRONG_FIELDS.each do |field, kind|
        Array(record.data[field]).each { |value| values << [kind, value] }
      end
      if record.data["website"]
        domain = domain_from(record.data["website"])
        values << [:domain, domain] if domain
      end
      values
    end

    def normalize(kind, value)
      string = value.to_s.strip
      case kind
      when :email, :external_id, :isbn, :iso_code then string.downcase
      when :phone then string.start_with?("+") ? "+#{string.gsub(/\D/, '')}" : string.gsub(/\D/, "")
      when :domain then domain_from(string) || string.downcase.sub(/\Awww\./, "")
      when :name then string.downcase.gsub(/[^[:alnum:]]+/, " ").strip
      else string
      end
    end

    def domain_from(value)
      candidate = value.to_s.downcase.strip
      return nil if candidate.include?("@")

      candidate = "https://#{candidate}" unless candidate.include?("://")
      host = URI.parse(candidate).host
      host&.sub(/\Awww\./, "")
    rescue URI::InvalidURIError
      nil
    end

    def collapse_redirects(matches)
      collapsed = {}
      matches.each do |match|
        resolved = @repository.resolve(match.record.id)
        entry = collapsed[resolved.id] ||= { record: resolved, signals: Set.new }
        match.signals.each { |signal| entry[:signals] << signal }
      end
      collapsed.values.map do |entry|
        IdentityMatch.new(record: entry.fetch(:record), signals: entry.fetch(:signals).to_a.sort.freeze).freeze
      end
    end
  end
end
