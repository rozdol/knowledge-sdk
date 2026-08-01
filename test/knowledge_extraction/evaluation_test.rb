# frozen_string_literal: true

require_relative "test_support"

class KnowledgeExtractionEvaluationTest < Minitest::Test
  def test_golden_dataset_has_fifty_synthetic_multilingual_cases
    dataset = JSON.parse(File.read(dataset_path))
    cases = dataset.fetch("cases")
    assert_equal 50, cases.length
    distribution = cases.group_by { |item| item.fetch("source").fetch("language") }.transform_values(&:length)
    assert_equal({ "en" => 24, "ru" => 10, "el" => 8, "mixed" => 4, "und" => 4 }, distribution)
    assert cases.all? { |item| item.fetch("id").match?(/\A(?:en|ru|el|mix|adv)-\d{2}\z/) }
    refute_includes File.read(dataset_path), "@gmail.com"
    assert cases.any? { |item| item.fetch("category") == "prompt-injection" }
    assert cases.any? { |item| item.fetch("category") == "corrections" }
    assert cases.any? { |item| item.fetch("category") == "ocr" }
    assert cases.any? { |item| item.fetch("expected").fetch("intent_types").empty? }
  end

  def test_offline_replay_evaluation_is_exact_and_calibrated
    with_schema_vault do |vault_root|
      reader = KnowledgeGraph::GraphReader.new(vault_root: vault_root)
      report = KnowledgeExtraction::EvaluationRunner.new(
        dataset_path: dataset_path, graph_reader: reader
      ).run
      assert_equal 50, report.fetch("case_count")
      assert_equal 50, report.fetch("passed_cases")
      assert_equal 1.0, report.fetch("fact_extraction").fetch("f1")
      assert_equal 1.0, report.fetch("intent_planning").fetch("f1")
      assert_equal 1.0, report.fetch("evidence").fetch("span_validity")
      assert_equal 0.0, report.fetch("entity_resolution").fetch("false_merge_rate")
      assert_equal 0.0, report.fetch("intent_planning").fetch("unsafe_intent_rate")
      assert_equal 0, report.fetch("provider_errors")
      assert_operator report.fetch("calibration").length, :>=, 3
    end
  end

  def test_report_writer_generates_all_required_reports
    with_vault do |directory|
      with_schema_vault do |vault_root|
        reader = KnowledgeGraph::GraphReader.new(vault_root: vault_root)
        report = KnowledgeExtraction::EvaluationRunner.new(
          dataset_path: dataset_path, graph_reader: reader, reports_dir: directory
        ).run
        assert_equal 50, report.fetch("passed_cases")
        KnowledgeExtraction::EvaluationReportWriter::FILES.each do |name|
          path = File.join(directory, name)
          assert File.file?(path), name
          assert File.read(path).start_with?("#"), name
        end
      end
    end
  end

  private

  def dataset_path
    File.join(__dir__, "golden/cases.json")
  end
end
