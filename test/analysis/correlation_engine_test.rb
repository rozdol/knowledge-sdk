# frozen_string_literal: true

require_relative "../test_helper"

class KnowledgeAnalysisCorrelationEngineTest < Minitest::Test
  def test_alignment_trend_correlation_and_event_windows_are_deterministic
    engine = KnowledgeAnalysis::CorrelationEngine.new
    first = 4.times.map do |index|
      { "time" => "2026-0#{index + 1}-01T00:00:00Z", "value" => index + 1 }
    end
    second = 4.times.map do |index|
      { "time" => "2026-0#{index + 1}-02T00:00:00Z", "value" => (index + 1) * 10 }
    end

    trend = engine.trend(first)
    assert_equal "increasing", trend.fetch("direction")
    assert_equal 4, trend.fetch("observations")
    correlation = engine.correlate(first, second, window_days: 3)
    assert_equal 1.0, correlation.fetch("coefficient")
    assert_equal false, correlation.fetch("causal")
    assert_match(/do not establish causality/, correlation.fetch("causal_hint"))

    comparison = engine.compare_around(
      first, event_time: "2026-03-01T00:00:00Z", before_days: 70, after_days: 70
    )
    assert_equal "increasing", comparison.fetch("direction")
    assert_equal false, comparison.fetch("causal")
  end
end
