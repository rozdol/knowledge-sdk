# frozen_string_literal: true

require_relative "test_support"

class IntelligenceGraphAlgorithmsTest < Minitest::Test
  def graph
    KnowledgeIntelligence::Projection.new(
      nodes: %w[a b c d e],
      edges: [
        { id: "ab", source: "a", target: "b" }, { id: "bc", source: "b", target: "c" },
        { id: "cd", source: "c", target: "d" }, { id: "be", source: "b", target: "e" }
      ]
    )
  end

  def test_bfs_dfs_shortest_path_and_components
    assert_equal %w[a b c e d], KnowledgeIntelligence::GraphAlgorithms.bfs(graph, "a")
    assert_equal %w[a b c d e], KnowledgeIntelligence::GraphAlgorithms.dfs(graph, "a")
    assert_equal %w[a b c d], KnowledgeIntelligence::GraphAlgorithms.shortest_path(graph, "a", "d")
    assert_equal [%w[a b c d e]], KnowledgeIntelligence::GraphAlgorithms.connected_components(graph)
  end

  def test_bridges_centrality_and_communities
    assert_equal [%w[a b], %w[b c], %w[b e], %w[c d]], KnowledgeIntelligence::GraphAlgorithms.bridges(graph)
    degree = KnowledgeIntelligence::GraphAlgorithms.degree_centrality(graph)
    betweenness = KnowledgeIntelligence::GraphAlgorithms.betweenness_centrality(graph)
    communities = KnowledgeIntelligence::GraphAlgorithms.communities(graph)

    assert_operator degree["b"], :>, degree["a"]
    assert_operator betweenness["b"], :>, betweenness["a"]
    assert_equal graph.nodes, communities.keys.sort
  end
end
