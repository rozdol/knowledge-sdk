# frozen_string_literal: true

require_relative "test_support"

class IntelligencePerformanceTest < Minitest::Test
  def test_linear_graph_operations_on_synthetic_scale_fixture
    size = ENV["KI_FULL_PERFORMANCE"] == "1" ? 100_000 : 5_000
    edge_target = ENV["KI_FULL_PERFORMANCE"] == "1" ? 1_000_000 : 25_000
    nodes = size.times.map { |index| format("node_%06d", index) }
    edges = []
    index = 0
    while edges.length < edge_target
      source = nodes[index % size]
      target = nodes[(index * 37 + 1) % size]
      if source != target
        edges << { id: "edge_#{index}", source: source, target: target }
      end
      index += 1
    end

    graph = KnowledgeIntelligence::Projection.new(nodes: nodes, edges: edges)
    components = KnowledgeIntelligence::GraphAlgorithms.connected_components(graph)
    degree = KnowledgeIntelligence::GraphAlgorithms.degree_centrality(graph)

    assert_equal size, graph.nodes.length
    assert_equal size, degree.length
    refute_empty components
  end
end
