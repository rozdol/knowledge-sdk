# frozen_string_literal: true

require "date"
require "json"
require "time"

module StructuredDataset
  class Search
    def initialize(engine:, clock: nil)
      @engine = engine
      @clock = clock || -> { Time.now }
    end

    def query(text)
      source = text.to_s.strip
      case source
      when /\Awhat (?:was|is) my latest weight\??\z/i
        latest_row(source, "weight", "observed_at")
      when /\A(?:what (?:was|is) )?my latest (?:blood test for )?(.+?)\??\z/i
        latest_blood_test(source, Regexp.last_match(1))
      when /\A(?:show|what is|how has) my blood pressure trend(?: over .+?)?\??\z/i
        trend(source, "blood_pressure", "observed_at", %w[systolic diastolic pulse])
      when /\A(?:show|what is|how has) my weight trend(?: over .+?)?\??\z/i
        trend(source, "weight", "observed_at", %w[weight_kg])
      when /\Awhat is the trend of (.+?) during the last year\??\z/i
        blood_test_trend(source, Regexp.last_match(1))
      else
        nil
      end
    rescue DatasetNotFound
      nil
    end

    private

    def latest_blood_test(source, marker)
      cleaned = marker.sub(/\?\z/, "").strip
      escaped = cleaned.gsub("'", "''")
      rows = @engine.query(
        "blood_tests", where: "marker LIKE '#{escaped}'", order: "observed_at:desc", limit: 1
      )
      result(source, "latest_dataset_value", "blood_tests", rows,
             "Selected the newest matching laboratory row through the validated dataset query layer.")
    end

    def latest_row(source, dataset, time_column)
      rows = @engine.query(dataset, order: "#{time_column}:desc", limit: 1)
      result(source, "latest_dataset_value", dataset, rows,
             "Selected the newest row through the validated dataset query layer.")
    end

    def trend(source, dataset, time_column, columns)
      rows = @engine.query(
        dataset, order: "#{time_column}:asc", limit: 366,
        columns: ([time_column] + columns + %w[row_id source observation_id proposal_id approval_id]).join(",")
      )
      result(source, "dataset_trend", dataset, rows,
             "Returned time-ordered measurements; interpretation remains outside SQLite.")
    end

    def blood_test_trend(source, marker)
      cleaned = marker.sub(/\?\z/, "").strip
      start = (@clock.call.to_date << 12).iso8601
      escaped = cleaned.gsub("'", "''")
      where = "marker LIKE '#{escaped}' AND observed_at >= '#{start}'"
      rows = @engine.query("blood_tests", where: where, order: "observed_at:asc", limit: 1_000)
      result(source, "dataset_trend", "blood_tests", rows,
             "Selected one year of matching rows; trend interpretation is performed outside SQLite.")
    end

    def result(query, kind, dataset, rows, explanation)
      description = @engine.describe(dataset)
      return nil if description["sensitivity"] == "restricted"

      {
        "query" => query, "kind" => kind, "answers" => rows,
        "dataset" => {
          "dataset_id" => description.fetch("dataset_id"), "slug" => description.fetch("slug"),
          "graph_path" => description.fetch("graph_path"), "purpose" => description.fetch("purpose")
        },
        "explanation" => explanation
      }
    end
  end

  class PlanningAdapter
    def initialize(engine:, clock: nil)
      @engine = engine
      @clock = clock || -> { Time.now }
    end

    def signals(_goal = nil)
      @engine.list.each_with_object([]) do |dataset, result|
        next if dataset["sensitivity"] == "restricted"

        case dataset.fetch("slug")
        when "weight" then append_numeric_trend(result, "weight", "observed_at", "weight_kg")
        when "blood_tests" then append_biomarker_trends(result)
        when "blood_pressure"
          append_numeric_trend(result, "blood_pressure", "observed_at", "systolic")
          append_numeric_trend(result, "blood_pressure", "observed_at", "diastolic")
        when "medication_log" then append_missed_medication(result)
        when "expenses" then append_recurring_expenses(result)
        end
      rescue StructuredDataset::Error
        next
      end.freeze
    end

    private

    def append_numeric_trend(result, dataset, time_column, value_column)
      rows = @engine.query(
        dataset, order: "#{time_column}:asc", limit: 365,
        columns: "#{time_column},#{value_column},row_id"
      ).select { |row| !row[value_column].nil? }
      return if rows.length < 2

      first = rows.first.fetch(value_column).to_f
      last = rows.last.fetch(value_column).to_f
      result << {
        "kind" => "numeric_trend", "dataset" => dataset, "metric" => value_column,
        "first" => first, "last" => last, "absolute_change" => (last - first).round(6),
        "observations" => rows.length, "from" => rows.first[time_column], "to" => rows.last[time_column],
        "interpretation" => "none"
      }
    end

    def append_missed_medication(result)
      start = (@clock.call.to_date - 30).iso8601
      rows = @engine.query(
        "medication_log", where: "observed_at >= '#{start}' AND action = 'missed'", limit: 10_000,
        columns: "observed_at,medication,row_id"
      )
      return if rows.empty?

      result << {
        "kind" => "missed_medication_doses", "dataset" => "medication_log",
        "window_days" => 30, "count" => rows.length, "row_ids" => rows.map { |row| row["row_id"] }
      }
    end

    def append_biomarker_trends(result)
      rows = @engine.query(
        "blood_tests", order: "observed_at:asc", limit: 10_000,
        columns: "observed_at,marker,value,unit,row_id"
      ).select { |row| !row["value"].nil? }
      rows.group_by { |row| [row["marker"], row["unit"]] }.each do |(marker, unit), matches|
        next if matches.length < 2

        first = matches.first.fetch("value").to_f
        last = matches.last.fetch("value").to_f
        change = (last - first).round(6)
        result << {
          "kind" => "biomarker_trend", "dataset" => "blood_tests", "marker" => marker,
          "unit" => unit, "first" => first, "last" => last, "absolute_change" => change,
          "direction" => change.positive? ? "increasing" : change.negative? ? "decreasing" : "stable",
          "observations" => matches.length, "from" => matches.first["observed_at"],
          "to" => matches.last["observed_at"], "interpretation" => "none"
        }
      end
    end

    def append_recurring_expenses(result)
      rows = @engine.query("expenses", order: "occurred_on:asc", limit: 10_000, columns: "occurred_on,category,amount,currency,row_id")
      groups = rows.group_by { |row| [row["category"], row["amount"], row["currency"]] }
      groups.each do |(category, amount, currency), matches|
        next if matches.length < 3

        result << {
          "kind" => "recurring_expense", "dataset" => "expenses", "category" => category,
          "amount" => amount, "currency" => currency, "occurrences" => matches.length,
          "row_ids" => matches.map { |row| row["row_id"] }
        }
      end
    end
  end

  class ObservationRecognizer
    BLOOD_PRESSURE = /\bmy blood pressure(?: today)? was\s+(\d{2,3})\s+(?:over|\/)\s+(\d{2,3})(?:\s+(?:with (?:a )?pulse(?: of)?|pulse)\s+(\d{2,3}))?/i.freeze

    def recognize(document, self_entity)
      return nil unless self_entity

      match = BLOOD_PRESSURE.match(document.content)
      return nil unless match

      observed_at = (document.captured_at || Time.now).iso8601
      evidence = {
        "source_id" => document.source_id, "start_offset" => match.begin(0),
        "end_offset" => match.end(0), "excerpt" => document.content[match.begin(0)...match.end(0)]
      }
      mention_id = KnowledgeExtraction::Support.stable_id("mention", document.source_id, self_entity.id)
      values = {
        "observed_at" => observed_at, "systolic" => match[1].to_i,
        "diastolic" => match[2].to_i
      }
      values["pulse"] = match[3].to_i if match[3]
      {
        "summary" => "Detected one structured blood pressure observation.",
        "mentions" => [{
          "mention_id" => mention_id, "entity_type" => "person",
          "display_name" => self_entity.name || self_entity.id,
          "external_ids" => [self_entity.id], "evidence" => [evidence]
        }],
        "facts" => [{
          "fact_type" => "dataset_observation", "subject_mention_id" => mention_id,
          "predicate" => "blood_pressure",
          "object" => {
            "kind" => "scalar", "value" => values, "value_type" => "json",
            "original_expression" => match[0], "normalized_value" => values,
            "normalization_confidence" => 0.99
          },
          "confidence" => 0.99, "status" => "asserted", "evidence" => [evidence],
          "qualifiers" => { "dataset_slug" => "blood_pressure" }
        }],
        "warnings" => []
      }
    end
  end

  class ActivityAdapter
    def initialize(vault_root:)
      @vault_root = vault_root
      @database = Database.new(vault_root: vault_root)
    end

    def audits
      return [] unless @database.path.file?

      registry = Registry.new(vault_root: @vault_root)
      names = registry.all.to_h { |record| [record.id, record.data["name"]] }
      @database.migrate!
      @database.with_connection do |connection|
        @database.activities(connection).map do |activity|
          action = activity.fetch("action")
          dataset_id = activity.fetch("dataset_id")
          {
            "id" => activity.fetch("activity_id"), "result" => "success",
            "timestamp" => activity.fetch("created_at"), "run_id" => activity["run_id"],
            "actor_id" => activity.fetch("actor_id"), "intent_type" => "Dataset#{action.capitalize}",
            "entity_ids" => [dataset_id], "changed_paths" => ["sqlite:#{dataset_id}:#{activity['row_id'] || action}"],
            "dataset_name" => names[dataset_id] || dataset_id, "dataset_action" => action,
            "row_id" => activity["row_id"], "source" => activity.fetch("source"),
            "proposal_id" => activity["proposal_id"], "approval_id" => activity["approval_id"],
            "observation_id" => activity["observation_id"],
            "fingerprint" => KnowledgeOrchestration::Stable.digest(activity),
            "intent" => { "params" => { "dataset_id" => dataset_id, "row_id" => activity["row_id"] } }
          }
        end
      end
    rescue StructuredDataset::Error
      []
    end
  end
end
