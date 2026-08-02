# frozen_string_literal: true

require "date"
require "time"

module KnowledgeAnalysis
  class PluginRegistry
    def initialize
      @plugins = {}
    end

    def register(plugin)
      unless plugin.respond_to?(:name) && plugin.respond_to?(:supports?) && plugin.respond_to?(:analyze)
        raise InvalidAnalysis, "analysis plugin must expose name, supports?, and analyze"
      end
      name = plugin.name.to_s
      raise InvalidAnalysis, "analysis plugin name is required" if name.empty?
      existing = @plugins[name]
      if existing && existing.class != plugin.class
        raise InvalidAnalysis, "analysis plugin #{name} conflicts with an existing registration"
      end

      @plugins[name] = plugin
      self
    end

    def all
      @plugins.keys.sort.map { |name| @plugins.fetch(name) }.freeze
    end
  end

  class IntentClassifierPlugin
    PATTERN = /\b(?:why|correlat(?:e|es|ed|ion)|possible reasons?|contributing factors?|what changed|shortly before|after i|after my|deteriorat(?:e|ed)|improv(?:e|ed)|increas(?:e|ed)|decreas(?:e|ed)|preceded|longest time|trend across|compare datasets?|medications?\s+(?:were\s+)?active|medications?\s+(?:was|were|am|is)\s+i\s+taking|taking\s+in\s+[a-z]+)\b/i.freeze

    class << self
      def register(classifier = KnowledgeSDK.intent_classifier)
        KnowledgeSDK::IntentClassifier::DOMAINS.each do |domain|
          classifier.register(
            name: "knowledge-analysis-core-#{domain}", domain: domain, route: "analyze"
          ) do |text, _context|
            next nil unless PATTERN.match?(text)

            {
              "intent" => "analysis.cross_knowledge", "confidence" => 0.96,
              "explanation" => "question requests deterministic cross-source analysis"
            }
          end
        end
      end
    end
  end

  class AnalysisContext
    attr_reader :question, :datasets, :snapshot, :activities, :events,
                :intelligence_findings, :planning_signals, :correlations,
                :from, :to, :as_of

    def initialize(question:, datasets:, snapshot:, activities:, events:,
                   intelligence_findings:, planning_signals:, correlations:,
                   from:, to:, as_of:)
      @question = question.to_s.freeze
      @datasets = datasets.freeze
      @snapshot = snapshot
      @activities = activities.freeze
      @events = events.freeze
      @intelligence_findings = intelligence_findings.freeze
      @planning_signals = planning_signals.freeze
      @correlations = correlations
      @from = from
      @to = to
      @as_of = as_of
      freeze
    end

    def dataset(slug)
      datasets[slug.to_s]
    end

    def series(slug, value:, time: nil, rows: nil)
      source = dataset(slug)
      return [] unless source

      time_column = time || source.fetch("time_column", nil)
      return [] unless time_column

      Array(rows || source.fetch("rows")).each_with_object([]) do |row, points|
        next if row[time_column].nil? || row[value.to_s].nil?

        points << {
          "time" => row.fetch(time_column), "value" => row.fetch(value.to_s),
          "row_id" => row["row_id"]
        }
      end
    end

    def numeric_series
      datasets.keys.sort.flat_map do |slug|
        source = datasets.fetch(slug)
        source.fetch("numeric_columns").sort.map do |column|
          points = series(slug, value: column)
          { "dataset" => slug, "column" => column, "points" => points } unless points.empty?
        end.compact
      end
    end

    def graph_matches(terms, limit: 20)
      needles = Array(terms).map { |term| term.to_s.downcase }.reject(&:empty?).uniq
      return [] if needles.empty?

      snapshot.records.each_with_object([]) do |record, result|
        next if record["sensitivity"] == "restricted"

        text = ([record.name, record.type] + record.data.values).flatten.compact.join(" ").downcase
        next unless needles.any? { |needle| text.include?(needle) }

        fields = record.data.keys.select do |field|
          needles.any? { |needle| record.data[field].to_s.downcase.include?(needle) }
        end.sort.first(5)
        result << {
          "record_id" => record.id, "record_type" => record.type,
          "name" => record.name, "fields" => fields
        }.reject { |_key, value| value.nil? }
        break if result.length >= limit
      end
    end

    def relevant_activities(terms, limit: 20)
      needles = Array(terms).map { |term| term.to_s.downcase }.reject(&:empty?).uniq
      selected = activities.select do |activity|
        text = [activity.summary, activity.source, activity.type].join(" ").downcase
        needles.empty? || needles.any? { |needle| text.include?(needle) }
      end
      selected.last(limit).map(&:to_h)
    end

    def factor(label:, association:, confidence:, datasets:, evidence:, window: nil,
               direction: nil, limitations: [])
      identifier = KnowledgeExtraction::Support.stable_id(
        "factor", label, association, Array(datasets).sort.join(","), evidence.to_s
      )
      {
        "factor_id" => identifier, "label" => label,
        "association" => association, "confidence" => bounded(confidence),
        "datasets" => Array(datasets).map(&:to_s).uniq.sort,
        "evidence" => evidence, "time_window" => window,
        "direction" => direction, "causal" => false,
        "limitations" => Array(limitations)
      }.reject { |_key, value| value.nil? || (value.respond_to?(:empty?) && value.empty?) }
    end

    private

    def bounded(value)
      [[value.to_f, 0.0].max, 1.0].min.round(6)
    end
  end

  module Plugins
    class Base
      def name
        self.class::NAME
      end

      def contributions
        {
          "analyzers" => [name], "correlation_rules" => [],
          "dataset_interpreters" => [], "recommendation_generators" => [],
          "explanation_templates" => []
        }
      end

      private

      def fragment(summary:, confidence:, factors: [], correlations: [], graph_evidence: [],
                   activity_evidence: [], windows: [], recommendations: [], limitations: [])
        {
          "plugin" => name, "summary" => summary, "confidence" => confidence.to_f.round(6),
          "possible_factors" => factors, "correlations" => correlations,
          "graph_evidence" => graph_evidence, "activity_evidence" => activity_evidence,
          "time_windows" => windows, "recommendations" => recommendations,
          "limitations" => limitations
        }
      end

      def recommendation(text, confidence:, evidence: [])
        {
          "recommendation_id" => KnowledgeExtraction::Support.stable_id("recommendation", name, text),
          "text" => text, "confidence" => confidence.to_f.round(6),
          "evidence" => evidence, "status" => "proposal_only", "executed" => false
        }
      end
    end

    class Health < Base
      NAME = "health"
      KEYWORDS = /\b(?:ldl|hdl|cholesterol|blood pressure|weight|sleep|medications?|berberine|blood marker|lab|health)\b/i.freeze

      def supports?(question, context)
        KEYWORDS.match?(question) && %w[blood_tests blood_pressure weight sleep medication_log medication_schedules].any? do |slug|
          context.dataset(slug)
        end
      end

      def contributions
        super.merge(
          "correlation_rules" => %w[health_numeric_alignment medication_event_window],
          "dataset_interpreters" => %w[blood_tests blood_pressure weight sleep medication_log medication_schedules],
          "recommendation_generators" => ["health_review"],
          "explanation_templates" => ["possible_contributing_factors"]
        )
      end

      def analyze(context)
        target = target_series(context)
        return medication_inventory_fragment(context) if !target && medication_question?(context.question)
        return fragment(
          summary: "The available health datasets do not contain enough matching observations.",
          confidence: 0.0,
          limitations: ["No matching numeric health series was available for the question."]
        ) unless target

        trend = context.correlations.trend(target.fetch("points"), from: context.from, to: context.to)
        factors = []
        correlations = []
        windows = []
        if trend
          windows << trend.slice("from", "to", "observations")
          factors << context.factor(
            label: "#{target.fetch('label')} trend",
            association: "#{target.fetch('label')} was #{trend.fetch('direction')} over the observed window.",
            confidence: trend.fetch("confidence"), datasets: [target.fetch("dataset")],
            evidence: trend, window: windows.last, direction: trend.fetch("direction"),
            limitations: ["The trend compares observations and does not identify a cause."]
          )
          medication_interval_factors(context, trend.fetch("from"), trend.fetch("to")).each do |factor|
            factors << factor
          end
        end

        candidate_series(context, target).first(30).each do |candidate|
          correlation = context.correlations.correlate(
            target.fetch("points"), candidate.fetch("points"), window_days: 7
          )
          next unless correlation && correlation.fetch("coefficient").abs >= 0.2

          correlations << correlation.merge(
            "left" => target.fetch("label"), "right" => candidate.fetch("label"),
            "datasets" => [target.fetch("dataset"), candidate.fetch("dataset")].uniq
          )
          factors << context.factor(
            label: candidate.fetch("label"),
            association: "#{candidate.fetch('label')} had a #{correlation.fetch('strength')} " \
                         "#{correlation.fetch('direction')} association with #{target.fetch('label')}.",
            confidence: correlation.fetch("confidence"),
            datasets: [target.fetch("dataset"), candidate.fetch("dataset")],
            evidence: correlation,
            limitations: [correlation.fetch("causal_hint")]
          )
        end

        event_factors(context, target).each do |item|
          factors << item.fetch("factor")
          windows << item.fetch("window")
        end
        factors = factors.sort_by { |item| [-item.fetch("confidence"), item.fetch("factor_id")] }.first(12)
        graph = context.graph_matches(question_terms(context.question), limit: 20)
        activity = context.relevant_activities(
          [target.fetch("dataset").tr("_", " "), target.fetch("label")], limit: 20
        )
        confidence = factors.empty? ? 0.0 : (factors.sum { |item| item.fetch("confidence") } / factors.length).round(6)
        summary = if trend
                    "#{target.fetch('label')} was #{trend.fetch('direction')} from #{trend.fetch('from')} to #{trend.fetch('to')}."
                  else
                    "#{target.fetch('label')} has too few observations for a trend estimate."
                  end
        recommendations = []
        if trend && trend.fetch("direction") != "stable"
          recommendations << recommendation(
            "Review the #{target.fetch('label')} trend and the listed possible contributing factors with a qualified professional before changing treatment or medication.",
            confidence: [confidence, trend.fetch("confidence")].min,
            evidence: factors.first(3).map { |item| item.fetch("factor_id") }
          )
        end
        fragment(
          summary: summary, confidence: confidence, factors: factors,
          correlations: correlations, graph_evidence: graph,
          activity_evidence: activity, windows: windows.uniq,
          recommendations: recommendations,
          limitations: health_limitations(target, trend, correlations)
        )
      end

      private

      def medication_question?(question)
        question.match?(/\b(?:medication|medications|medicine|taking|dose|berberine)\b/i)
      end

      def medication_inventory_fragment(context)
        rows = active_medication_rows(context, context.from, context.to)
        factors = rows.map do |row|
          medication_factor(context, row, context.from, context.to)
        end
        names = rows.map { |row| row["medication"].to_s }.reject(&:empty?).uniq.sort
        summary = if names.empty?
                    "No active medication schedules overlapped the requested interval."
                  else
                    "Active medication schedules in the requested interval: #{names.join(', ')}."
                  end
        fragment(
          summary: summary, confidence: factors.empty? ? 0.0 : 0.95,
          factors: factors, windows: [{
            "from" => context.from && context.from.iso8601,
            "to" => context.to && context.to.iso8601,
            "observations" => rows.length
          }],
          activity_evidence: context.relevant_activities(["medication schedules"], limit: 20),
          limitations: [
            "Medication membership is determined from structured effective intervals; unrecorded treatment is not included.",
            "The result describes recorded schedules and is not medical advice."
          ]
        )
      end

      def medication_interval_factors(context, from, to)
        active_medication_rows(context, from, to).map do |row|
          medication_factor(context, row, from, to)
        end
      end

      def active_medication_rows(context, from, to)
        source = context.dataset("medication_schedules")
        return [] unless source

        source.fetch("rows").select do |row|
          enabled = row["active"] == true || row["active"] == 1
          enabled && KnowledgeSDK::Schedule.active_during?(
            row["effective_from"] || row["effective_on"], row["effective_until"],
            from: from, to: to
          )
        end.sort_by do |row|
          [row["medication"].to_s.downcase, row["effective_from"].to_s, row["schedule_id"].to_s]
        end
      end

      def medication_factor(context, row, from, to)
        schedule = row["schedule_json"]
        begin
          schedule = KnowledgeSDK::Schedule.from_h(schedule).to_h if schedule
        rescue ArgumentError
          schedule = nil
        end
        interval = {
          "effective_from" => row["effective_from"] || row["effective_on"],
          "effective_until" => row["effective_until"],
          "analysis_from" => from && from.to_s, "analysis_to" => to && to.to_s
        }
        evidence = interval.merge(
          "schedule_id" => row["schedule_id"] || row["row_id"],
          "dose" => row["dose"], "unit" => row["unit"],
          "route" => row["route"], "schedule" => schedule
        ).reject { |_key, value| value.nil? }
        context.factor(
          label: row["medication"].to_s,
          association: "#{row['medication']} had an active structured schedule overlapping the analysis window.",
          confidence: 0.95, datasets: ["medication_schedules"],
          evidence: evidence, window: interval,
          limitations: ["Temporal overlap does not establish that the medication caused the observed change."]
        )
      end

      def target_series(context)
        question = context.question.downcase
        tests = context.dataset("blood_tests")
        if tests
          markers = tests.fetch("rows").map { |row| row["marker"] }.compact.map(&:to_s).uniq
          marker = markers.sort_by { |value| [-value.length, value] }.find do |value|
            question.include?(value.downcase)
          end
          marker ||= markers.sort.first if question.match?(/blood marker|biomarker|blood test|lab/)
          if marker
            rows = tests.fetch("rows").select { |row| row["marker"].to_s.casecmp?(marker) }
            return {
              "label" => marker, "dataset" => "blood_tests",
              "column" => "value",
              "points" => context.series("blood_tests", value: "value", rows: rows)
            }
          end
        end
        return health_target(context, "blood_pressure", "systolic", "systolic blood pressure") if question.include?("blood pressure")
        return health_target(context, "weight", "weight_kg", "weight") if question.include?("weight")
        if question.include?("sleep")
          column = context.dataset("sleep")&.fetch("numeric_columns", [])&.include?("quality") ? "quality" : "duration_hours"
          return health_target(context, "sleep", column, "sleep #{column.to_s.tr('_', ' ')}")
        end
        nil
      end

      def health_target(context, dataset, column, label)
        points = context.series(dataset, value: column)
        points.empty? ? nil : {
          "label" => label, "dataset" => dataset, "column" => column, "points" => points
        }
      end

      def candidate_series(context, target)
        candidates = context.numeric_series.each_with_object([]) do |series, result|
          next if series.fetch("dataset") == target.fetch("dataset") &&
                  series.fetch("column") == target.fetch("column")
          next unless %w[blood_tests blood_pressure weight sleep exercise nutrition medication_log].include?(series.fetch("dataset"))

          result << series.merge(
            "label" => "#{series.fetch('dataset').tr('_', ' ')} #{series.fetch('column').tr('_', ' ')}"
          )
        end
        candidates.concat(medication_adherence_series(context)) if target.fetch("dataset") == "sleep"
        candidates
      end

      def medication_adherence_series(context)
        source = context.dataset("medication_log")
        return [] unless source

        source.fetch("rows").group_by { |row| row["medication"].to_s }.keys.sort.each_with_object([]) do |medication, result|
          next if medication.empty?

          rows = source.fetch("rows").select { |row| row["medication"].to_s == medication }
          points = rows.each_with_object([]) do |row, values|
            score = case row["action"].to_s
                    when "taken" then 1.0
                    when "missed", "skipped" then 0.0
                    end
            values << { "time" => row["observed_at"], "value" => score } unless score.nil?
          end
          next if points.empty?

          result << {
            "dataset" => "medication_log", "column" => "action",
            "label" => "#{medication} adherence", "points" => points
          }
        end
      end

      def event_factors(context, target)
        medication = context.question[/\b(?:stopped|stop|removed|taking|increased|increase|increasing|decreased|decrease)\s+(?:taking\s+|the\s+dose\s+of\s+)?([A-Za-z][A-Za-z0-9 .'-]{1,40})/i, 1]
        return [] unless medication

        rows = []
        %w[medication_log medication_schedules].each do |slug|
          source = context.dataset(slug)
          next unless source

          source.fetch("rows").each do |row|
            rows << [slug, row] if row["medication"].to_s.downcase.include?(medication.strip.downcase)
          end
        end
        rows.each_with_object([]) do |(slug, row), result|
          event_time = row["observed_at"] || row["effective_from"] || row["effective_on"] || row["updated_at"]
          comparison = event_time && context.correlations.compare_around(
            target.fetch("points"), event_time: event_time, before_days: 90, after_days: 90
          )
          next unless comparison

          result << {
            "window" => comparison.slice("event_time", "before", "after"),
            "factor" => context.factor(
              label: "#{medication.strip} timing",
              association: "#{target.fetch('label')} changed around a recorded #{medication.strip} medication event.",
              confidence: comparison.fetch("confidence"),
              datasets: [target.fetch("dataset"), slug], evidence: comparison,
              limitations: ["The before/after timing is a causal hint only and may be confounded."]
            )
          }
        end
      end

      def question_terms(question)
        question.downcase.scan(/[a-z][a-z0-9-]{2,}/).reject do |word|
          %w[why has have increased during last months show possible reasons which with after taking].include?(word)
        end.first(12)
      end

      def health_limitations(target, trend, correlations)
        limitations = [
          "Associations are observational and must not be interpreted as medical causality.",
          "Unrecorded diet, illness, adherence, measurement conditions, and clinical context may confound the result."
        ]
        limitations << "Fewer than two matching observations were available." unless trend
        limitations << "No aligned cross-dataset series had at least three comparable observations." if correlations.empty?
        limitations << "The analysis used only records available to the local SDK for #{target.fetch('label')}."
        limitations
      end
    end

    class Finance < Base
      NAME = "finance"
      KEYWORDS = /\b(?:expense|expenses|subscription|subscriptions|income|spending|finance|monthly|cost)\b/i.freeze

      def supports?(question, context)
        KEYWORDS.match?(question) && %w[expenses subscriptions income].any? { |slug| context.dataset(slug) }
      end

      def contributions
        super.merge(
          "correlation_rules" => %w[monthly_totals recurring_category_change],
          "dataset_interpreters" => %w[expenses subscriptions income],
          "recommendation_generators" => ["expense_review"],
          "explanation_templates" => ["monthly_expense_drivers"]
        )
      end

      def analyze(context)
        expense = context.dataset("expenses")
        unless expense
          return fragment(
            summary: "No expense dataset is available for the finance question.", confidence: 0.0,
            limitations: ["Monthly expense analysis requires dated expense observations."]
          )
        end
        totals = monthly_totals(expense.fetch("rows"))
        trend_points = totals.map { |month, value| { "time" => "#{month}-01", "value" => value } }
        trend = context.correlations.trend(trend_points, from: context.from, to: context.to)
        factors = category_factors(context, expense.fetch("rows"))
        factors.concat(subscription_factors(context))
        factors = factors.sort_by { |item| [-item.fetch("confidence"), item.fetch("factor_id")] }.first(15)
        confidence = factors.empty? ? (trend && trend.fetch("confidence") || 0.0) :
          (factors.sum { |item| item.fetch("confidence") } / factors.length).round(6)
        summary = if trend
                    "Monthly recorded expenses were #{trend.fetch('direction')} across #{totals.length} month(s)."
                  else
                    "Recorded expenses cover too few months for a monthly trend."
                  end
        recommendations = factors.empty? ? [] : [recommendation(
          "Review the highest-confidence recurring categories or subscriptions before changing the monthly budget.",
          confidence: confidence, evidence: factors.first(5).map { |item| item.fetch("factor_id") }
        )]
        fragment(
          summary: summary, confidence: confidence, factors: factors,
          windows: trend ? [trend.slice("from", "to", "observations")] : [],
          graph_evidence: context.graph_matches(%w[subscription expense budget], limit: 20),
          activity_evidence: context.relevant_activities(%w[expenses subscriptions], limit: 20),
          recommendations: recommendations,
          limitations: [
            "Only recorded transactions are included; missing or duplicated expenses can change the result.",
            "Recurring timing is an association and does not prove that a subscription caused unrelated spending."
          ]
        )
      end

      private

      def monthly_totals(rows)
        rows.each_with_object(Hash.new(0.0)) do |row, result|
          month = row["occurred_on"].to_s[0, 7]
          result[month] += row["amount"].to_f if month.match?(/\A\d{4}-\d{2}\z/)
        end.sort.to_h
      end

      def category_factors(context, rows)
        months = rows.map { |row| row["occurred_on"].to_s[0, 7] }.select { |value| value.match?(/\A\d{4}-\d{2}\z/) }.uniq.sort
        return [] if months.length < 2

        split = [(months.length / 2.0).ceil, 1].max
        before = months.first(split)
        after = months.drop(split)
        after = [months.last] if after.empty?
        groups = rows.group_by { |row| [row["category"].to_s, row["currency"].to_s] }
        groups.each_with_object([]) do |((category, currency), matches), result|
          first = matches.select { |row| before.include?(row["occurred_on"].to_s[0, 7]) }.sum { |row| row["amount"].to_f } / before.length
          last = matches.select { |row| after.include?(row["occurred_on"].to_s[0, 7]) }.sum { |row| row["amount"].to_f } / after.length
          change = last - first
          next unless change.positive?

          confidence = [0.45 + matches.length * 0.05, 0.9].min
          evidence = {
            "before_months" => before, "after_months" => after,
            "before_monthly_average" => first.round(6),
            "after_monthly_average" => last.round(6), "increase" => change.round(6),
            "currency" => currency, "observations" => matches.length
          }
          result << context.factor(
            label: category.empty? ? "uncategorized expenses" : category,
            association: "Average recorded monthly spending for #{category} increased by #{change.round(2)} #{currency}.",
            confidence: confidence, datasets: ["expenses"], evidence: evidence,
            direction: "increasing"
          )
        end
      end

      def subscription_factors(context)
        source = context.dataset("subscriptions")
        return [] unless source

        source.fetch("rows").select { |row| row["active"] == true || row["active"] == 1 }.map do |row|
          monthly = monthly_amount(row["amount"].to_f, row["billing_period"])
          context.factor(
            label: row["service"].to_s,
            association: "#{row['service']} contributes approximately #{monthly.round(2)} #{row['currency']} per month while active.",
            confidence: 0.85, datasets: ["subscriptions"],
            evidence: {
              "amount" => row["amount"], "billing_period" => row["billing_period"],
              "monthly_equivalent" => monthly.round(6), "row_id" => row["row_id"]
            },
            limitations: ["Monthly equivalence assumes a regular billing period and excludes taxes or usage charges."]
          )
        end
      end

      def monthly_amount(amount, period)
        case period.to_s.downcase
        when /year|annual/ then amount / 12.0
        when /week/ then amount * 52.0 / 12.0
        when /quarter/ then amount / 3.0
        else amount
        end
      end
    end

    class CRM < Base
      NAME = "crm"

      def supports?(question, context)
        question.match?(/\b(?:contacted|contact|follow up|longest time|crm)\b/i) &&
          !context.snapshot.records(type: "person").empty?
      end

      def analyze(context)
        people = context.snapshot.records(type: "person").reject { |record| record["is_self"] == true }
        ranked = people.map do |person|
          interactions = context.snapshot.interactions_for(person.id, as_of: context.as_of)
          latest = interactions.map { |record| context.snapshot.parse_time(record["starts_at"]) }.compact.max
          [person, latest]
        end.sort_by { |person, latest| [latest ? latest.to_i : 0, person.name.to_s, person.id] }
        factors = ranked.first(20).map do |person, latest|
          days = latest ? (context.as_of - latest.to_date).to_i : nil
          context.factor(
            label: person.name || person.id,
            association: latest ? "Last recorded contact was #{latest.iso8601} (#{days} days ago)." : "No recorded contact was found.",
            confidence: latest ? 0.95 : 0.65, datasets: [],
            evidence: { "person_id" => person.id, "last_contacted_at" => latest && latest.iso8601, "days" => days }
          )
        end
        fragment(
          summary: factors.empty? ? "No contacts were available." : "#{factors.first.fetch('label')} has the oldest recorded contact state.",
          confidence: factors.empty? ? 0.0 : factors.first.fetch("confidence"),
          factors: factors,
          graph_evidence: ranked.first(20).map { |person, _latest| { "record_id" => person.id, "name" => person.name } },
          limitations: ["Only graph interactions recorded in the Vault are considered."]
        )
      end
    end

    class Generic < Base
      NAME = "generic"

      def supports?(_question, _context)
        true
      end

      def analyze(context)
        series = context.numeric_series.select { |item| item.fetch("points").length >= 3 }.first(20)
        correlations = []
        series.combination(2).each do |first, second|
          next if first.fetch("dataset") == second.fetch("dataset")

          value = context.correlations.correlate(first.fetch("points"), second.fetch("points"), window_days: 7)
          next unless value && value.fetch("coefficient").abs >= 0.4

          correlations << value.merge(
            "left" => "#{first.fetch('dataset')}.#{first.fetch('column')}",
            "right" => "#{second.fetch('dataset')}.#{second.fetch('column')}",
            "datasets" => [first.fetch("dataset"), second.fetch("dataset")].sort
          )
        end
        correlations = correlations.sort_by do |item|
          [-item.fetch("coefficient").abs, item.fetch("left"), item.fetch("right")]
        end.first(10)
        factors = correlations.map do |item|
          context.factor(
            label: "#{item.fetch('left')} ↔ #{item.fetch('right')}",
            association: "The aligned series had a #{item.fetch('strength')} #{item.fetch('direction')} association.",
            confidence: item.fetch("confidence"), datasets: item.fetch("datasets"),
            evidence: item, limitations: [item.fetch("causal_hint")]
          )
        end
        fragment(
          summary: factors.empty? ? "No supported cross-dataset association met the evidence threshold." :
            "Found #{factors.length} deterministic cross-dataset association(s).",
          confidence: factors.empty? ? 0.0 : factors.first.fetch("confidence"),
          factors: factors, correlations: correlations,
          limitations: ["Generic correlations are exploratory and do not supply domain-specific causal interpretation."]
        )
      end
    end
  end
end
