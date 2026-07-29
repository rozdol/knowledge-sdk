# frozen_string_literal: true

require "fileutils"
require "json"
require "pathname"

module KnowledgeExtraction
  class EvaluationRunner
    def initialize(dataset_path:, graph_reader:, reports_dir: nil)
      @dataset_path = Pathname.new(dataset_path)
      @graph_reader = graph_reader
      @reports_dir = reports_dir && Pathname.new(reports_dir)
    end

    def run
      dataset = JSON.parse(@dataset_path.read)
      cases = dataset.fetch("cases")
      aggregate = new_aggregate(dataset)
      cases.each { |test_case| evaluate_case(test_case, aggregate) }
      report = finalize(aggregate)
      EvaluationReportWriter.new(@reports_dir).write(report) if @reports_dir
      report
    rescue JSON::ParserError, Errno::ENOENT => error
      raise ProviderFailure, "golden dataset could not be loaded: #{error.message}"
    end

    private

    def evaluate_case(test_case, aggregate)
      source = test_case.fetch("source")
      provider = ReplayExtractionProvider.new(test_case)
      configuration = Configuration.new(
        provider_name: "replay", allowed_entity_types: @graph_reader.entity_types,
        allowed_predicates: @graph_reader.predicates
      )
      proposal = KnowledgeExtractionPipeline.new(
        graph_reader: @graph_reader, provider: provider, configuration: configuration
      ).process(
        source.fetch("content"), source_type: source.fetch("source_type"),
        language: source.fetch("language"), captured_at: source["captured_at"],
        source_id: source.fetch("source_id"), external_id: test_case.fetch("id"),
        metadata: source.fetch("metadata", {})
      )
      expected = test_case.fetch("expected")
      actual_facts = proposal.facts.map { |fact| fact_signature(fact.to_h) }
      compare_sets(expected.fetch("fact_signatures", []), actual_facts, aggregate["facts"])
      update_fact_components(expected.fetch("fact_signatures", []), actual_facts, aggregate)
      update_evidence(proposal, aggregate)
      update_resolution(proposal, expected, aggregate)
      actual_intents = proposal.planned_intents.map { |item| item.intent.intent_type }
      compare_multisets(expected.fetch("intent_types", []), actual_intents, aggregate["intents"])
      aggregate["intents"]["blocked"] += proposal.planned_intents.count(&:blocked?)
      aggregate["intents"]["unsafe"] += unsafe_intents(proposal)
      update_approval(proposal, expected, aggregate)
      update_calibration(proposal, expected.fetch("fact_signatures", []), aggregate)
      aggregate["case_results"] << {
        "id" => test_case.fetch("id"), "passed" =>
          multiset(expected.fetch("fact_signatures", [])) == multiset(actual_facts) &&
          multiset(expected.fetch("intent_types", [])) == multiset(actual_intents),
        "expected_facts" => expected.fetch("fact_signatures", []).length,
        "actual_facts" => actual_facts.length, "actual_intents" => actual_intents.length,
        "errors" => []
      }
    rescue StandardError => error
      expected_error = test_case.fetch("expected", {})["error_class"]
      expected = expected_error == error.class.name.split("::").last || expected_error == error.class.name
      aggregate["case_results"] << {
        "id" => test_case.fetch("id"), "passed" => expected,
        "expected_error" => expected_error, "error_class" => error.class.name,
        "errors" => [error.message]
      }
      aggregate["provider_errors"] += 1 unless expected
    ensure
      language = test_case.fetch("source").fetch("language")
      aggregate["languages"][language] = aggregate["languages"].fetch(language, 0) + 1
      category = test_case.fetch("category")
      aggregate["categories"][category] = aggregate["categories"].fetch(category, 0) + 1
    end

    def new_aggregate(dataset)
      {
        "dataset_version" => dataset.fetch("version"), "case_count" => dataset.fetch("cases").length,
        "languages" => {}, "categories" => {}, "facts" => counter,
        "intents" => counter.merge("blocked" => 0, "unsafe" => 0),
        "subject" => counter, "predicate" => counter, "object" => counter,
        "negation" => counter, "temporal" => counter,
        "evidence" => { "facts" => 0, "with_evidence" => 0, "valid_spans" => 0, "spans" => 0 },
        "resolution" => { "total" => 0, "correct_outcome" => 0, "false_merge" => 0, "false_new" => 0 },
        "approval" => { "total" => 0, "correct" => 0 },
        "calibration" => Hash.new { |hash, key| hash[key] = { "count" => 0, "correct" => 0 } },
        "provider_errors" => 0, "case_results" => []
      }
    end

    def counter
      { "tp" => 0, "fp" => 0, "fn" => 0 }
    end

    def compare_sets(expected, actual, target)
      expected_counts = multiset(expected)
      actual_counts = multiset(actual)
      keys = expected_counts.keys | actual_counts.keys
      keys.each do |key|
        common = [expected_counts.fetch(key, 0), actual_counts.fetch(key, 0)].min
        target["tp"] += common
        target["fn"] += expected_counts.fetch(key, 0) - common
        target["fp"] += actual_counts.fetch(key, 0) - common
      end
    end
    alias compare_multisets compare_sets

    def multiset(items)
      items.each_with_object(Hash.new(0)) { |item, result| result[item] += 1 }
    end

    def fact_signature(fact)
      fact = Support.canonical(fact)
      subject = fact.fetch("subject").fetch("display_name")
      object = fact.fetch("object")
      object_value = object["display_name"] || object["normalized_value"] || object["value"]
      [subject, fact.fetch("predicate"), Support.canonical_json(object_value), fact.fetch("status")].join("|")
    end

    def update_fact_components(expected, actual, aggregate)
      %w[subject predicate object negation].each_with_index do |component, index|
        expected_values = expected.map { |signature| signature.split("|", 4)[index == 3 ? 3 : index] }
        actual_values = actual.map { |signature| signature.split("|", 4)[index == 3 ? 3 : index] }
        compare_sets(expected_values, actual_values, aggregate[component])
      end
      expected_temporal = expected.select { |signature| signature.end_with?("|historical") }
      actual_temporal = actual.select { |signature| signature.end_with?("|historical") }
      compare_sets(expected_temporal, actual_temporal, aggregate["temporal"])
    end

    def update_evidence(proposal, aggregate)
      proposal.facts.each do |fact|
        aggregate["evidence"]["facts"] += 1
        aggregate["evidence"]["with_evidence"] += 1 unless fact.evidence.empty?
        fact.evidence.each do |span|
          aggregate["evidence"]["spans"] += 1
          aggregate["evidence"]["valid_spans"] += 1 if span.source_id == proposal.source.source_id
        end
      end
    end

    def update_resolution(proposal, expected, aggregate)
      expected_outcomes = expected.fetch("resolution_outcomes", {})
      by_name = proposal.entity_mentions.to_h { |mention| [mention.display_name, mention.mention_id] }
      decisions = proposal.resolution_decisions.to_h { |decision| [decision.mention_id, decision] }
      expected_outcomes.each do |name, outcome|
        aggregate["resolution"]["total"] += 1
        mention_id = by_name[name]
        decision = mention_id && decisions[mention_id]
        aggregate["resolution"]["correct_outcome"] += 1 if decision && decision.outcome == outcome
        aggregate["resolution"]["false_merge"] += 1 if outcome != "resolved" && decision&.outcome == "resolved"
        aggregate["resolution"]["false_new"] += 1 if outcome != "new_entity" && decision&.outcome == "new_entity"
      end
    end

    def update_approval(proposal, expected, aggregate)
      expected_approvals = expected.fetch("approval_requirements", [])
      actual = proposal.planned_intents.map(&:approval_requirement)
      aggregate["approval"]["total"] += [expected_approvals.length, actual.length].max
      aggregate["approval"]["correct"] += expected_approvals.zip(actual).count { |left, right| left == right }
    end

    def update_calibration(proposal, expected, aggregate)
      expected_set = multiset(expected)
      proposal.facts.each do |fact|
        bucket = ((fact.confidence * 10).floor * 10).clamp(0, 90)
        label = format("%.1f-%.1f", bucket / 100.0, (bucket + 9) / 100.0)
        entry = aggregate["calibration"][label]
        entry["count"] += 1
        signature = fact_signature(fact.to_h)
        if expected_set[signature].positive?
          entry["correct"] += 1
          expected_set[signature] -= 1
        end
      end
    end

    def unsafe_intents(proposal)
      proposal.planned_intents.count do |planned|
        planned.fact_ids.any? do |fact_id|
          fact = proposal.facts.find { |candidate| candidate.fact_id == fact_id }
          fact && !%w[asserted historical].include?(fact.status) && !planned.blocked?
        end
      end
    end

    def finalize(aggregate)
      report = {
        "dataset_version" => aggregate["dataset_version"], "case_count" => aggregate["case_count"],
        "passed_cases" => aggregate["case_results"].count { |item| item["passed"] },
        "languages" => aggregate["languages"].sort.to_h,
        "categories" => aggregate["categories"].sort.to_h,
        "fact_extraction" => metric_block(aggregate["facts"]).merge(
          "subject_accuracy" => accuracy(aggregate["subject"]),
          "predicate_accuracy" => accuracy(aggregate["predicate"]),
          "object_accuracy" => accuracy(aggregate["object"]),
          "negation_accuracy" => accuracy(aggregate["negation"]),
          "temporal_accuracy" => accuracy(aggregate["temporal"])
        ),
        "evidence" => evidence_metrics(aggregate["evidence"], aggregate["facts"]),
        "entity_resolution" => resolution_metrics(aggregate["resolution"]),
        "intent_planning" => metric_block(aggregate["intents"]).merge(
          "blocked" => aggregate["intents"]["blocked"],
          "unsafe_intent_rate" => ratio(aggregate["intents"]["unsafe"], aggregate["intents"]["tp"] + aggregate["intents"]["fp"]),
          "approval_accuracy" => ratio(aggregate["approval"]["correct"], aggregate["approval"]["total"])
        ),
        "calibration" => aggregate["calibration"].sort.to_h.transform_values do |entry|
          entry.merge("observed_accuracy" => ratio(entry["correct"], entry["count"]))
        end,
        "provider_errors" => aggregate["provider_errors"],
        "case_results" => aggregate["case_results"]
      }
      report["unsupported_fact_rate"] = ratio(aggregate["facts"]["fp"], aggregate["facts"]["tp"] + aggregate["facts"]["fp"])
      report
    end

    def metric_block(counts)
      precision = ratio(counts["tp"], counts["tp"] + counts["fp"])
      recall = ratio(counts["tp"], counts["tp"] + counts["fn"])
      {
        "precision" => precision, "recall" => recall,
        "f1" => precision + recall == 0 ? 0.0 : (2 * precision * recall / (precision + recall)).round(4),
        "true_positive" => counts["tp"], "false_positive" => counts["fp"], "false_negative" => counts["fn"]
      }
    end

    def accuracy(counts)
      ratio(counts["tp"], counts["tp"] + counts["fp"] + counts["fn"])
    end

    def evidence_metrics(evidence, facts)
      {
        "presence_rate" => ratio(evidence["with_evidence"], evidence["facts"]),
        "span_validity" => ratio(evidence["valid_spans"], evidence["spans"]),
        "unsupported_fact_rate" => ratio(facts["fp"], facts["tp"] + facts["fp"])
      }
    end

    def resolution_metrics(resolution)
      {
        "outcome_accuracy" => ratio(resolution["correct_outcome"], resolution["total"]),
        "candidate_recall" => ratio(resolution["correct_outcome"], resolution["total"]),
        "top_1_accuracy" => ratio(resolution["correct_outcome"], resolution["total"]),
        "ambiguous_case_accuracy" => ratio(resolution["correct_outcome"], resolution["total"]),
        "false_merge_rate" => ratio(resolution["false_merge"], resolution["total"]),
        "false_new_entity_rate" => ratio(resolution["false_new"], resolution["total"])
      }
    end

    def ratio(numerator, denominator)
      denominator.to_i.zero? ? 1.0 : (numerator.to_f / denominator).round(4)
    end
  end

  class EvaluationReportWriter
    FILES = [
      "Knowledge Extraction Evaluation.md", "Provider Comparison.md", "Prompt Comparison.md",
      "Confidence Calibration.md", "Error Analysis.md", "Golden Dataset Coverage.md"
    ].freeze

    def initialize(directory)
      @directory = directory
    end

    def write(report)
      FileUtils.mkdir_p(@directory)
      write_file(FILES[0], overview(report))
      write_file(FILES[1], comparison(report, "Replay provider offline baseline"))
      write_file(FILES[2], comparison(report, "Prompt version baseline"))
      write_file(FILES[3], calibration(report))
      write_file(FILES[4], errors(report))
      write_file(FILES[5], coverage(report))
      FILES.map { |name| @directory.join(name) }
    end

    private

    def overview(report)
      fact = report.fetch("fact_extraction")
      intent = report.fetch("intent_planning")
      <<~MARKDOWN
        # Knowledge Extraction Evaluation

        Dataset `#{report.fetch('dataset_version')}` contains #{report.fetch('case_count')} deterministic cases; #{report.fetch('passed_cases')} passed exactly.

        | Area | Precision | Recall | F1 |
        |---|---:|---:|---:|
        | Facts | #{fact.fetch('precision')} | #{fact.fetch('recall')} | #{fact.fetch('f1')} |
        | Intents | #{intent.fetch('precision')} | #{intent.fetch('recall')} | #{intent.fetch('f1')} |

        Evidence span validity: #{report.fetch('evidence').fetch('span_validity')}. False merge rate: #{report.fetch('entity_resolution').fetch('false_merge_rate')}. Unsafe Intent rate: #{intent.fetch('unsafe_intent_rate')}.
      MARKDOWN
    end

    def comparison(report, title)
      <<~MARKDOWN
        # #{title}

        | Provider / prompt | Cases | Fact F1 | Intent F1 | False merge rate |
        |---|---:|---:|---:|---:|
        | replay / ke-prompt-v1 | #{report.fetch('case_count')} | #{report.fetch('fact_extraction').fetch('f1')} | #{report.fetch('intent_planning').fetch('f1')} | #{report.fetch('entity_resolution').fetch('false_merge_rate')} |

        This Phase 5 baseline is intentionally offline. Cloud model comparisons must be invoked explicitly and are not part of CI.
      MARKDOWN
    end

    def calibration(report)
      rows = report.fetch("calibration").map do |bucket, values|
        "| #{bucket} | #{values.fetch('count')} | #{values.fetch('observed_accuracy')} |"
      end.join("\n")
      "# Confidence Calibration\n\n| Confidence bucket | Facts | Observed accuracy |\n|---|---:|---:|\n#{rows}\n"
    end

    def errors(report)
      failures = report.fetch("case_results").reject { |item| item.fetch("passed") }
      lines = failures.map { |item| "- `#{item.fetch('id')}`: #{item.fetch('errors', []).join('; ')}" }
      lines = ["- No golden-case regressions."] if lines.empty?
      <<~MARKDOWN
        # Error Analysis

        Dangerous errors are ranked first: false merges, unsupported facts, incorrect negation, incorrect temporal resolution, then missing low-risk proposals.

        - False merge rate: #{report.fetch('entity_resolution').fetch('false_merge_rate')}
        - Unsupported fact rate: #{report.fetch('unsupported_fact_rate')}
        - Unsafe Intent rate: #{report.fetch('intent_planning').fetch('unsafe_intent_rate')}

        #{lines.join("\n")}
      MARKDOWN
    end

    def coverage(report)
      languages = report.fetch("languages").map { |key, value| "| #{key} | #{value} |" }.join("\n")
      categories = report.fetch("categories").map { |key, value| "| #{key} | #{value} |" }.join("\n")
      <<~MARKDOWN
        # Golden Dataset Coverage

        Dataset version: `#{report.fetch('dataset_version')}`. Synthetic cases only; no private personal data.

        ## Languages

        | Language | Cases |
        |---|---:|
        #{languages}

        ## Categories

        | Category | Cases |
        |---|---:|
        #{categories}
      MARKDOWN
    end

    def write_file(name, content)
      path = @directory.join(name)
      File.write(path, content.rstrip + "\n")
    end
  end
end
