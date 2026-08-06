# frozen_string_literal: true

module KnowledgeCapture
  class Linker
    Candidate = Struct.new(:entity_id, :name, :entity_type, :category, :confidence, :reason, keyword_init: true) do
      def to_h
        {
          "entity_id" => entity_id, "name" => name, "entity_type" => entity_type,
          "category" => category, "confidence" => confidence, "reason" => reason
        }.freeze
      end
    end

    def initialize(vault_root:, registry: KnowledgeCapture.registry)
      @vault_root = vault_root
      @registry = registry
    end

    def candidates(text)
      source = normalize(text)
      graph = graph_candidates(source)
      plugin = @registry.link_candidates(text, "vault_root" => @vault_root)
                        .map { |item| normalize_candidate(item) }
      (graph + plugin).uniq { |item| [item.entity_id, item.category] }
                      .sort_by { |item| [-item.confidence, item.name.downcase, item.entity_id] }.freeze
    end

    private

    def graph_candidates(source)
      snapshot = KnowledgeIntelligence::GraphSnapshot.load(vault_root: @vault_root)
      snapshot.records.each_with_object([]) do |record, result|
        next if record["sensitivity"] == "restricted"

        names = ([record.name] + Array(record["aliases"])).compact.map(&:to_s).reject { |name| name.length < 2 }
        matched = names.sort_by { |name| -name.length }.find { |name| phrase?(source, normalize(name)) }
        next unless matched

        category = case record.type
                   when "project" then "project"
                   when "person" then "contact"
                   when "organization" then "entity"
                   else "entity"
                   end
        result << Candidate.new(
          entity_id: record.id, name: record.name || matched, entity_type: record.type,
          category: category, confidence: 0.92,
          reason: "the capture explicitly mentions a canonical #{record.type} name or alias"
        ).freeze
      end
    rescue KnowledgeGraph::Error
      []
    end

    def normalize_candidate(item)
      data = item.respond_to?(:to_h) ? item.to_h : item
      data = data.transform_keys(&:to_s)
      Candidate.new(
        entity_id: data.fetch("entity_id").to_s, name: data.fetch("name").to_s,
        entity_type: data.fetch("entity_type").to_s,
        category: data.fetch("category", "entity").to_s,
        confidence: Float(data.fetch("confidence", 0.5)),
        reason: data.fetch("reason", "trusted capture auto-linker candidate").to_s
      ).freeze
    rescue KeyError, ArgumentError, TypeError => error
      raise PluginError, "invalid capture link candidate: #{error.message}"
    end

    def phrase?(source, phrase)
      return false if phrase.empty?

      source.match?(/(?:\A|[^\p{L}\p{N}])#{Regexp.escape(phrase)}(?:\z|[^\p{L}\p{N}])/u)
    end

    def normalize(value)
      value.to_s.encode(Encoding::UTF_8).unicode_normalize(:nfc).downcase.tr("ё", "е")
    end
  end
end
