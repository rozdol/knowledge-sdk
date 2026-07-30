# frozen_string_literal: true

module KnowledgePlanning
  class GraphSearch
    attr_reader :snapshot, :as_of

    def initialize(snapshot:, as_of: Date.today)
      @snapshot = snapshot
      @as_of = as_of.is_a?(Date) ? as_of : Date.iso8601(as_of.to_s)
      @projections = {}
    end

    def shortest_path(source_id, target_id, mode: "auto")
      projection = projection_for(source_id, target_id, mode)
      KnowledgeIntelligence::GraphAlgorithms.shortest_path(projection, source_id, target_id)
    end

    def alternative_paths(source_id, target_id, mode: "auto", limit: 3, max_depth: 5)
      projection = projection_for(source_id, target_id, mode)
      return [] unless projection.nodes.include?(source_id.to_s) && projection.nodes.include?(target_id.to_s)

      target = target_id.to_s
      queue = [[source_id.to_s]]
      found = []
      until queue.empty? || found.length >= limit.to_i
        path = queue.shift
        next if path.length - 1 > max_depth.to_i
        if path.last == target
          found << path.freeze
          next
        end
        projection.neighbors(path.last).sort.each do |neighbor|
          next if path.include?(neighbor)

          queue << (path + [neighbor])
        end
        queue.sort_by! { |candidate| [candidate.length, candidate.join("|")] }
      end
      found.freeze
    end

    def edge_evidence(path, mode: "auto")
      return [] if !path || path.length < 2

      projection = projection_for(path.first, path.last, mode)
      path.each_cons(2).flat_map do |first, second|
        projection.edge_ids(first, second).map do |edge_id|
          edge = projection.edge_records.fetch(edge_id)
          record = snapshot.record(edge["record_id"])
          record && snapshot.evidence(record, role: "plan_path_edge")
        end.compact
      end.uniq(&:evidence_id).sort_by(&:evidence_id).freeze
    end

    def direct_contact?(source_id, target_id)
      path = shortest_path(source_id, target_id, mode: "social")
      path && path.length == 2
    end

    private

    def projection_for(source_id, target_id, mode)
      selected = mode.to_s
      if selected == "auto"
        source = snapshot.record(source_id)
        target = snapshot.record(target_id)
        selected = source&.type == "person" && target&.type == "person" ? "social" : "knowledge"
      end
      raise InvalidPlan, "search mode must be social or knowledge" unless %w[social knowledge].include?(selected)

      @projections[selected] ||= if selected == "social"
                                   KnowledgeIntelligence::Projection.social(snapshot, as_of: as_of)
                                 else
                                   KnowledgeIntelligence::Projection.knowledge(snapshot, as_of: as_of)
                                 end
    end
  end
end
