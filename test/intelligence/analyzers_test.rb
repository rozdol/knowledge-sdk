# frozen_string_literal: true

require_relative "test_support"

class IntelligenceAnalyzersTest < Minitest::Test
  def setup
    @engine = KnowledgeIntelligence::AnalysisEngine.new(
      snapshot: rich_snapshot, analyzers: KnowledgeIntelligence::DefaultAnalyzers.build,
      as_of: AS_OF
    )
  end

  def test_analyzers_find_relationship_opportunity_gap_followup_and_network_scenarios
    run = @engine.run
    kinds = run.findings.map(&:kind)

    %w[
      inactive_contact bridge_person connector_person isolated_person missing_email duplicate_candidate
      possible_introduction investor_path overdue_followup broken_promise stale_project
      contradictory_preference network_bridge community_candidate briefing_card
    ].each { |kind| assert_includes kinds, kind }
    run.findings.each do |finding|
      refute_empty finding.explanation
      assert_operator finding.confidence, :>=, 0.0
      assert_operator finding.confidence, :<=, 1.0
    end
  end

  def test_analyzer_dependency_closure_runs_recommendation_sources_first
    run = @engine.run(names: ["recommendation"])
    analyzers = run.results.map(&:analyzer)

    assert_includes analyzers, "relationship"
    assert_includes analyzers, "followup"
    assert_includes analyzers, "recommendation"
    assert_includes run.findings.map(&:kind), "repair_commitment"
  end

  def test_common_analyzer_interface_accepts_graph_snapshot_directly
    result = KnowledgeIntelligence::Analyzers::Relationship.new.analyze(rich_snapshot, as_of: AS_OF)

    assert_instance_of KnowledgeIntelligence::AnalysisResult, result
    assert_equal "relationship", result.analyzer
    assert_includes result.findings.map(&:kind), "inactive_contact"
  end

  def test_identical_snapshot_and_date_produce_identical_output
    first = JSON.generate(@engine.run.to_h)
    second_engine = KnowledgeIntelligence::AnalysisEngine.new(
      snapshot: rich_snapshot, analyzers: KnowledgeIntelligence::DefaultAnalyzers.build,
      as_of: AS_OF
    )

    assert_equal first, JSON.generate(second_engine.run.to_h)
  end

  def test_intent_proposal_is_compatible_with_existing_approval_validator
    run = @engine.run(names: ["recommendation"])
    payload = KnowledgeIntelligence::ProposalAdapter.new.build(run)

    assert KnowledgeExtraction::ProposalValidator.new.validate!(payload)
    assert_equal "awaiting_approval", payload["status"]
    assert payload["planned_intents"].all? { |item| item["approval_requirement"] == "human_review" }
  end
end
