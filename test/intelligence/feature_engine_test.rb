# frozen_string_literal: true

require_relative "test_support"

class IntelligenceFeatureEngineTest < Minitest::Test
  def test_feature_registry_exposes_versioned_shared_features
    registry = KnowledgeIntelligence::DefaultFeatures.registry

    assert_equal %w[
      community_membership completeness_score graph_distance influence_score interaction_frequency
      recency_score relationship_strength trust_score
    ], registry.names
    assert_equal %w[recency_score interaction_frequency trust_score],
                 registry.fetch("relationship_strength").dependencies
  end

  def test_relationship_strength_reuses_dependency_cache_and_explains_formula
    engine = feature_engine

    first = engine.fetch("relationship_strength", subject_id: "person_ada")
    second = engine.fetch("relationship_strength", subject_id: "person_ada")

    assert_same first, second
    assert_operator first.value, :>, 0.2
    assert_operator first.value, :<, 0.8
    assert_includes first.explanation, "35% recency"
    assert_operator first.evidence.length, :>=, 2
    assert_equal 1, engine.metrics[:computations]["relationship_strength"]
    assert_equal 1, engine.metrics[:cache_hits]
  end

  def test_graph_distance_and_community_are_deterministic
    engine = feature_engine

    distance = engine.fetch("graph_distance", subject_id: "person_bob", object_id: "person_cara")
    community = engine.fetch("community_membership", subject_id: "person_bob")

    assert_equal 2, distance.value
    assert_equal ["person_bob", "person_ada", "person_cara"], distance.metadata["path"]
    assert_match(/\Acommunity:/, community.value)
    assert_operator community.metadata["size"], :>=, 3
  end

  def test_completeness_lists_missing_signals_without_persisting_them
    value = feature_engine.fetch("completeness_score", subject_id: "person_ada")

    assert_includes value.metadata["missing"], "email"
    assert_includes value.metadata["missing"], "phone"
    refute rich_snapshot.fetch("person_ada").data.key?("completeness_score")
  end
end
