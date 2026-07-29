# frozen_string_literal: true

require_relative "test_support"

class IntelligenceGoldenTest < Minitest::Test
  DATASET = File.expand_path("golden/cases.json", __dir__)

  def test_golden_scenarios
    cases = JSON.parse(File.read(DATASET)).fetch("cases")
    run = KnowledgeIntelligence::AnalysisEngine.new(
      snapshot: rich_snapshot, analyzers: KnowledgeIntelligence::DefaultAnalyzers.build, as_of: AS_OF
    ).run
    kinds = run.findings.map(&:kind)

    cases.each do |scenario|
      scenario.fetch("expected_findings").each do |expected|
        assert_includes kinds, expected, "#{scenario.fetch('id')} expected #{expected}"
      end
      scenario.fetch("expected_recommendations", []).each do |expected|
        assert_includes kinds, expected, "#{scenario.fetch('id')} expected recommendation #{expected}"
      end
    end
  end
end
