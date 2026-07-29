# frozen_string_literal: true

module KnowledgeExtraction
  class ResolutionCandidate < ImmutableModel
    attr_reader :mention_id, :canonical_entity_id, :entity_type, :display_name,
                :score, :matched_on, :conflicts, :explanation

    def initialize(mention_id:, canonical_entity_id:, entity_type:, display_name:, score:,
                   matched_on:, conflicts: [], explanation:)
      @mention_id = required_string(mention_id, "mention_id", maximum: 200)
      @canonical_entity_id = required_string(canonical_entity_id, "canonical_entity_id", maximum: 200)
      @entity_type = required_string(entity_type, "entity_type", maximum: 100)
      @display_name = optional_string(display_name, "display_name", maximum: 500)
      @score = validated_confidence(score, "resolution score")
      @matched_on = immutable(Array(matched_on).map(&:to_s).uniq.sort)
      @conflicts = immutable(Array(conflicts).map(&:to_s))
      @explanation = required_string(explanation, "explanation", maximum: 2_000)
      freeze
    end

    def to_h
      {
        mention_id: mention_id, canonical_entity_id: canonical_entity_id,
        entity_type: entity_type, display_name: display_name, score: score,
        matched_on: matched_on, conflicts: conflicts, explanation: explanation
      }
    end
  end

  class ResolutionDecision < ImmutableModel
    OUTCOMES = %w[resolved ambiguous new_entity conflict insufficient_information].freeze
    attr_reader :mention_id, :outcome, :candidates, :selected_entity_id, :explanation

    def initialize(mention_id:, outcome:, candidates:, selected_entity_id: nil, explanation:)
      @mention_id = required_string(mention_id, "mention_id", maximum: 200)
      @outcome = outcome.to_s.freeze
      raise EntityResolutionConflict, "invalid resolution outcome #{@outcome.inspect}" unless OUTCOMES.include?(@outcome)
      @candidates = immutable(candidates)
      @selected_entity_id = optional_string(selected_entity_id, "selected_entity_id", maximum: 200)
      if @outcome == "resolved" && @selected_entity_id.nil?
        raise EntityResolutionConflict, "resolved decision needs selected_entity_id"
      end
      @explanation = required_string(explanation, "explanation", maximum: 2_000)
      freeze
    end

    def selected_candidate
      candidates.find { |candidate| candidate.canonical_entity_id == selected_entity_id }
    end

    def to_h
      {
        mention_id: mention_id, outcome: outcome, candidates: candidates.map(&:to_h),
        selected_entity_id: selected_entity_id, explanation: explanation
      }
    end
  end

  class ConservativeEntityResolver
    def initialize(graph_reader:, configuration: Configuration.new)
      @graph_reader = graph_reader
      @configuration = configuration
    end

    def resolve(mentions)
      mentions.map { |mention| resolve_one(mention) }.freeze
    end

    private

    def resolve_one(mention)
      matches = collect_matches(mention)
      candidates = matches.values.map { |entry| candidate_for(mention, entry) }
                          .sort_by { |candidate| [-candidate.score, candidate.canonical_entity_id] }
      return decision(mention, "new_entity", [], nil, "No graph candidate matched any supplied identity signal") if candidates.empty?

      conflict_candidates = candidates.select { |candidate| !candidate.conflicts.empty? }
      unless conflict_candidates.empty?
        return decision(mention, "conflict", candidates, nil, "A candidate conflicts with supplied strong identity data")
      end

      strong = candidates.select { |candidate| (candidate.matched_on & %w[email phone external_id domain id]).any? }
      if strong.length == 1 && strong.first.score >= @configuration.automatic_candidate_resolution_threshold
        return decision(
          mention, "resolved", candidates, strong.first.canonical_entity_id,
          "Unique strong identity match met the automatic resolution threshold"
        )
      end
      if candidates.length > 1
        return decision(mention, "ambiguous", candidates, nil, "Multiple graph candidates require human selection")
      end
      if candidates.first.score < @configuration.minimum_entity_resolution_confidence
        return decision(
          mention, "insufficient_information", candidates, nil,
          "Candidate score is below the configured review threshold"
        )
      end

      decision(mention, "ambiguous", candidates, nil, "Name-only or contextual matching cannot resolve identity automatically")
    end

    def collect_matches(mention)
      queries = [[mention.display_name, false]]
      queries << [mention.email, true] if mention.email
      queries << [mention.phone, true] if mention.phone
      mention.external_ids.each { |external_id| queries << [external_id, true] }
      mention.aliases.each { |name| queries << [name, false] }
      matches = {}
      queries.each do |query, strong_only|
        @graph_reader.search(query, entity_type: mention.entity_type, strong_only: strong_only).each do |match|
          entity = match.fetch(:entity)
          entry = matches[entity.id] ||= { entity: entity, signals: [] }
          entry[:signals] |= match.fetch(:signals)
        end
      end
      matches
    end

    def candidate_for(mention, entry)
      entity = entry.fetch(:entity)
      signals = entry.fetch(:signals)
      score = if signals.include?("email") || signals.include?("phone")
                0.99
              elsif signals.include?("external_id") || signals.include?("domain")
                0.98
              elsif signals.include?("name")
                0.72
              else
                0.60
              end
      conflicts = []
      if mention.email && !entity.emails.empty? && !normalized_include?(entity.emails, mention.email)
        conflicts << "email differs from candidate"
      end
      if mention.phone && !entity.phones.empty? && !phone_include?(entity.phones, mention.phone)
        conflicts << "phone differs from candidate"
      end
      ResolutionCandidate.new(
        mention_id: mention.mention_id, canonical_entity_id: entity.id,
        entity_type: entity.type, display_name: entity.name, score: score,
        matched_on: signals, conflicts: conflicts,
        explanation: "Matched #{signals.empty? ? 'context' : signals.sort.join(', ')}"
      )
    end

    def normalized_include?(values, expected)
      values.any? { |value| value.to_s.strip.downcase == expected.to_s.strip.downcase }
    end

    def phone_include?(values, expected)
      normalized = expected.to_s.gsub(/\D/, "")
      values.any? { |value| value.to_s.gsub(/\D/, "") == normalized }
    end

    def decision(mention, outcome, candidates, selected, explanation)
      ResolutionDecision.new(
        mention_id: mention.mention_id, outcome: outcome, candidates: candidates,
        selected_entity_id: selected, explanation: explanation
      )
    end
  end
end
