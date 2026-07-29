# frozen_string_literal: true

module KnowledgeIntelligence
  class QueryResult
    attr_reader :query, :kind, :answers, :explanation

    def initialize(query:, kind:, answers:, explanation:)
      @query = query.to_s.freeze
      @kind = kind.to_s.freeze
      @answers = Immutable.copy(answers)
      @explanation = explanation.to_s.freeze
      freeze
    end

    def to_h
      { query: query, kind: kind, answers: answers, explanation: explanation }
    end
  end

  class QueryEngine
    def initialize(snapshot:, feature_engine:, as_of: Date.today)
      @snapshot = snapshot
      @features = feature_engine
      @as_of = as_of
    end

    def query(text)
      source = text.to_s.strip
      normalized = source.downcase
      case normalized
      when /\Awho do i know in (.+)\??\z/, /\Aкого я знаю (?:в|по теме) (.+)\??\z/u
        connected_to(source, Regexp.last_match(1))
      when /\Awho introduced me to (.+)\??\z/, /\Aкто познакомил меня с (.+)\??\z/u
        introducers(source, Regexp.last_match(1))
      when /\Awho have i ignored the longest\??\z/, /\Aкого я дольше всего игнорирую\??\z/u
        ignored_longest(source)
      when /\Awhich companies are connected\??\z/, /\Aкакие компании связаны\??\z/u
        connected_companies(source)
      when /\Awhat projects involve (.+)\??\z/, /\Aкакие проекты связаны с (.+)\??\z/u
        projects_involving(source, Regexp.last_match(1))
      else
        raise InvalidQuery, "unsupported deterministic query"
      end
    end

    private

    def connected_to(source, term)
      targets = find_named(term)
      target_ids = targets.map(&:id)
      people = @snapshot.records(type: "person").reject { |person| person.id == @snapshot.self_id }.select do |person|
        @snapshot.relationships(as_of: @as_of, entity_id: person.id).any? do |record|
          target_ids.include?(other_endpoint(record, person.id))
        end
      end
      answers = people.sort_by(&:name).map do |person|
        records = @snapshot.relationships(as_of: @as_of, entity_id: person.id).select do |record|
          target_ids.include?(other_endpoint(record, person.id))
        end
        answer(person, records)
      end
      QueryResult.new(
        query: source, kind: "people_connected_to", answers: answers,
        explanation: "Matched canonical names or aliases, then traversed asserted relationships."
      )
    end

    def introducers(source, term)
      targets = find_named(term, type: "person")
      self_id = @snapshot.self_id
      answers = @snapshot.records(type: "introduction").select do |record|
        pair = [record["person_a_id"], record["person_b_id"]]
        record["assertion_status"] == "asserted" && pair.include?(self_id) &&
          !(pair & targets.map(&:id)).empty?
      end.map do |record|
        introducer = @snapshot.record(record["introducer_id"])
        answer(introducer, [record])
      end.compact
      QueryResult.new(
        query: source, kind: "introducers", answers: answers,
        explanation: "Traversed asserted Introduction records where Self and the target form the introduced pair."
      )
    end

    def ignored_longest(source)
      people = @snapshot.records(type: "person").reject { |person| person.id == @snapshot.self_id }
      scored = people.map do |person|
        feature = @features.fetch("recency_score", subject_id: person.id)
        [person, feature]
      end.sort_by do |person, feature|
        [feature.metadata["days_since_interaction"] ? 0 : -1,
         -(feature.metadata["days_since_interaction"] || 1_000_000), person.id]
      end
      answers = scored.first(25).map do |person, feature|
        { id: person.id, name: person.name, path: person.path,
          days_since_interaction: feature.metadata["days_since_interaction"],
          recency_score: feature.value, evidence: feature.evidence.map(&:to_h) }
      end
      QueryResult.new(
        query: source, kind: "ignored_longest", answers: answers,
        explanation: "Sorted people by the latest substantive interaction with Self; missing interaction history ranks first."
      )
    end

    def connected_companies(source)
      organizations = @snapshot.records(type: "organization").select { |record| record["org_kind"] == "company" }
      answers = organizations.map do |organization|
        records = @snapshot.relationships(as_of: @as_of, entity_id: organization.id)
        answer(organization, records).merge("connection_count" => records.length)
      end.sort_by { |item| [-item["connection_count"], item["name"].to_s] }
      QueryResult.new(
        query: source, kind: "connected_companies", answers: answers,
        explanation: "Listed company Organizations and counted current asserted relationships."
      )
    end

    def projects_involving(source, term)
      targets = find_named(term)
      target_ids = targets.map(&:id)
      projects = @snapshot.records(type: "project").select do |project|
        structural = %w[parent_project technologies topics].any? do |field|
          !(@snapshot.reference_ids(project, field) & target_ids).empty?
        end
        semantic = @snapshot.relationships(as_of: @as_of, entity_id: project.id).any? do |record|
          target_ids.include?(other_endpoint(record, project.id))
        end
        structural || semantic
      end
      QueryResult.new(
        query: source, kind: "projects_involving",
        answers: projects.sort_by(&:name).map { |project| answer(project, []) },
        explanation: "Traversed project structural links and current asserted semantic relationships."
      )
    end

    def find_named(term, type: nil)
      normalized = normalize(term.sub(/\?\z/, ""))
      records = @snapshot.records(type: type).select do |record|
        ([record.name] + Array(record["aliases"])).compact.any? do |name|
          candidate = normalize(name)
          candidate == normalized || candidate.include?(normalized) || normalized.include?(candidate)
        end
      end
      raise InvalidQuery, "no canonical entity matches #{term.inspect}" if records.empty?

      records.sort_by(&:id)
    end

    def normalize(value)
      value.to_s.downcase.gsub(/[^\p{Alnum}]+/u, " ").strip
    end

    def other_endpoint(record, entity_id)
      record["subject_id"] == entity_id ? record["object_id"] : record["subject_id"]
    end

    def answer(record, evidence_records)
      return nil unless record

      {
        "id" => record.id, "name" => record.name, "type" => record.type, "path" => record.path,
        "evidence" => evidence_records.map { |item| @snapshot.evidence(item).to_h }
      }
    end
  end
end
