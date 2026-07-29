# frozen_string_literal: true

require_relative "test_support"

class IntelligenceQueryReportTest < Minitest::Test
  def setup
    @snapshot = rich_snapshot
    @features = feature_engine(@snapshot)
    @query = KnowledgeIntelligence::QueryEngine.new(
      snapshot: @snapshot, feature_engine: @features, as_of: AS_OF
    )
    @run = KnowledgeIntelligence::AnalysisEngine.new(
      snapshot: @snapshot, analyzers: KnowledgeIntelligence::DefaultAnalyzers.build, as_of: AS_OF
    ).run
  end

  def test_deterministic_natural_queries
    connected = @query.query("Who do I know in Synthetic AI?")
    ignored = @query.query("Who have I ignored the longest?")
    companies = @query.query("Which companies are connected?")

    assert_equal %w[person_ada person_bob person_faye], connected.answers.map { |answer| answer["id"] }.sort
    assert_equal "person_cara", ignored.answers.first["id"]
    assert_empty companies.answers
  end

  def test_digest_and_reports_are_source_backed
    digest = KnowledgeIntelligence::DigestBuilder.new(snapshot: @snapshot, as_of: AS_OF).build(@run, days: 30)
    network = KnowledgeIntelligence::ReportEngine.new(snapshot: @snapshot, as_of: AS_OF).build("network", @run)
    score = KnowledgeIntelligence::ReportEngine.new(snapshot: @snapshot, as_of: AS_OF).build("personal_crm", @run)

    assert_equal "monthly_digest", digest.name
    assert digest.sections.key?("knowledge_gaps")
    assert network.sections.key?("network")
    assert_operator score.metrics["score"], :>=, 0.0
    assert_operator score.metrics["score"], :<=, 100.0
  end
end
