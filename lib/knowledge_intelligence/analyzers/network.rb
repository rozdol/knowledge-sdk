# frozen_string_literal: true

module KnowledgeIntelligence
  module Analyzers
    class Network < Analyzer
      NAME = "network"
      VERSION = "1.0.0"

      def perform(context)
        graph = Projection.social(context.snapshot, as_of: context.as_of)
        degree = GraphAlgorithms.degree_centrality(graph)
        betweenness = GraphAlgorithms.betweenness_centrality(
          graph, max_sources: context.config.fetch(:betweenness_sources, 128)
        )
        components = GraphAlgorithms.connected_components(graph)
        bridges = GraphAlgorithms.bridges(graph)
        communities = GraphAlgorithms.communities(graph)
        findings = []
        components.each_with_index do |component, index|
          findings << finding(
            kind: "connected_component", title: "Network component #{index + 1}", entity_ids: component,
            confidence: 1.0, evidence: [], explanation: "This connected component contains #{component.length} people.",
            severity: component.length == 1 ? "low" : "info", tags: %w[network component],
            details: { size: component.length, component_id: component.first }
          )
        end
        bridges.each do |first, second|
          evidence = graph.edge_ids(first, second).map do |edge_id|
            edge = graph.edge_records[edge_id]
            record = edge && context.snapshot.record(edge["record_id"])
            record && context.evidence(record)
          end.compact
          findings << finding(
            kind: "network_bridge", title: "Network bridge: #{context.person_name(first)} ↔ #{context.person_name(second)}",
            entity_ids: [first, second], confidence: 1.0, evidence: evidence,
            explanation: "Removing this edge increases the number of connected components.",
            severity: "medium", priority: "high", tags: %w[network bridge], graph_path: [first, second]
          )
        end
        communities.values.uniq.sort.each do |label|
          members = communities.select { |_id, value| value == label }.keys.sort
          findings << finding(
            kind: "community_candidate", title: "Community candidate: #{context.person_name(label)} cluster",
            entity_ids: members, confidence: members.length > 1 ? 0.75 : 0.5, evidence: [],
            explanation: "Deterministic label propagation grouped #{members.length} people.",
            severity: "info", tags: %w[network community], details: { community_id: "community:#{label}", size: members.length }
          )
        end
        result(
          findings,
          metrics: {
            nodes: graph.nodes.length, edges: graph.edge_count, components: components.length,
            bridges: bridges.length, degree_centrality: degree, betweenness: betweenness,
            communities: communities
          }
        )
      end
    end
  end
end
