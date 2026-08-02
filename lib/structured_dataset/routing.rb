# frozen_string_literal: true

require "date"
require "time"

module StructuredDataset
  class MedicationScheduleParser
    RUSSIAN_VERB = /(?:принимаю|принимать|принимает|при[её]м|пью|выпиваю)/i.freeze
    RUSSIAN_EVENT = /(?:сегодня|\d{1,2}:\d{2}).*(?:принял|приняла|выпил|выпила)|(?:принял|приняла|выпил|выпила).*(?:сегодня|\d{1,2}:\d{2})/i.freeze
    RUSSIAN_TIME = {
      /(?:каждое\s+утро|\bутром\b)/i => "every morning",
      /(?:\bдн[её]м\b|каждый\s+день)/i => "every afternoon",
      /(?:\bвечером\b|каждый\s+вечер)/i => "every evening",
      /(?:на\s+ночь|каждую\s+ночь)/i => "every night",
      /два\s+раза\s+в\s+день/i => "twice daily",
      /раз\s+в\s+день/i => "once daily",
      /до\s+еды/i => "before meals",
      /после\s+еды/i => "after meals"
    }.freeze
    RUSSIAN_CONDITION = /(?:натощак|до\s+еды)/i.freeze
    RUSSIAN_ROUTE = /(?:под\s+язык|сублингвально)/i.freeze
    RUSSIAN_STRIP = /(?:\b(?:я|он|она|мы|вы|они)\b\s*|#{RUSSIAN_VERB}|каждое\s+утро|\bутром\b|\bдн[её]м\b|каждый\s+день|\bвечером\b|каждый\s+вечер|на\s+ночь|каждую\s+ночь|два\s+раза\s+в\s+день|раз\s+в\s+день|натощак|до\s+еды|после\s+еды|под\s+язык|сублингвально)/i.freeze
    RUSSIAN_UNIT = /(?:капсул(?:а|у|ы|е)|таблет(?:ка|ку|ки|ке)|капл(?:я|и)|мг|мкг|ме)/i.freeze
    QUANTITIES = {
      "один" => 1.0, "одна" => 1.0, "одно" => 1.0, "одну" => 1.0,
      "одной" => 1.0, "два" => 2.0, "две" => 2.0
    }.freeze

    def initialize(text_normalizer: KnowledgeSDK::ClassifierTextNormalizer.new)
      @text_normalizer = text_normalizer
    end

    def administration_event?(source)
      RUSSIAN_EVENT.match?(@text_normalizer.normalize(source).matching)
    end

    def parse(source, effective_from: nil, effective_until: nil, effective_on: nil)
      starts_on = effective_from || effective_on
      raise ArgumentError, "effective_from is required" if starts_on.to_s.empty?

      normalized = @text_normalizer.normalize(source)
      entries = if normalized.matching.match?(/[а-я]/i)
                  russian_entries(normalized.original, starts_on, effective_until)
                elsif normalized.matching.match?(/[α-ωάέήίόύώϊϋΐΰ]/i)
                  greek_entries(normalized.original, starts_on, effective_until)
                else
                  english_entries(normalized.original, starts_on, effective_until)
                end
      entries.empty? ? nil : entries.freeze
    end

    private

    def english_entries(source, effective_from, effective_until)
      sections = english_section_entries(source, effective_from, effective_until)
      return sections unless sections.empty?

      multiple = /\bi\s+(?:take|am\s+taking)\s+([a-z][a-z0-9 .'-]*?)(?:\s+(\d+(?:\.\d+)?)\s*(mg|mcg|g|ml|capsules?|tablets?|iu))?\s+((?:every\s+(?:morning|afternoon|evening|night|day))(?:\s*(?:,|and)\s*every\s+(?:morning|afternoon|evening|night|day))+)(?:\s+(on\s+an?\s+empty\s+stomach|before\s+food|after\s+food|sublingually|under\s+the\s+tongue))?[.!]?\z/i.match(source.gsub(/\s+/, " ").strip)
      if multiple
        return multiple[4].scan(/every\s+(?:morning|afternoon|evening|night|day)/i).map do |schedule|
          entry(
            medication: multiple[1], schedule: schedule.downcase,
            effective_from: effective_from, effective_until: effective_until,
            dose: multiple[2], unit: multiple[3], condition: multiple[5]
          )
        end
      end

      pattern = /\bi\s+(?:take|am\s+taking)\s+([a-z][a-z0-9 .'-]*?)(?:\s+(\d+(?:\.\d+)?)\s*(mg|mcg|g|ml|capsules?|tablets?|iu))?\s+(every\s+(?:morning|afternoon|evening|night|day)|once\s+daily|twice\s+daily|at\s+\d{1,2}(?::\d{2})?(?:\s*[ap]m)?)(?:\s+(on\s+an?\s+empty\s+stomach|before\s+food|after\s+food|sublingually|under\s+the\s+tongue))?[.!]?\z/i
      match = pattern.match(source.gsub(/\s+/, " ").strip)
      return [] unless match

      [entry(
        medication: match[1], schedule: match[4].downcase, effective_from: effective_from,
        effective_until: effective_until,
        dose: match[2], unit: match[3], condition: match[5]
      )]
    end

    def english_section_entries(source, effective_from, effective_until)
      entries = []
      time = nil
      source.lines.each do |line|
        text = line.strip
        next if text.empty?

        heading = /\A(morning|day|afternoon|evening|night)\s*:?\z/i.match(text)
        if heading
          time = heading[1].downcase == "day" ? "afternoon" : heading[1].downcase
          next
        end
        next unless time

        match = /\A([a-z][a-z0-9 .'-]*?)(?:\s+(\d+(?:\.\d+)?)\s*(mg|mcg|g|ml|capsules?|tablets?|iu))?[.!]?\z/i.match(text)
        next unless match

        entries << entry(
          medication: match[1], schedule: "every #{time}",
          effective_from: effective_from, effective_until: effective_until,
          dose: match[2], unit: match[3]
        )
      end
      entries.length >= 2 ? entries : []
    end

    def greek_entries(source, effective_from, effective_until)
      pattern = /(?:\A|\s)(?:εγώ\s+)?(?:παίρνω|λαμβάνω)\s+([[:alpha:]][[:alpha:]0-9 .'-]*?)(?:\s+(\d+(?:[.,]\d+)?)\s*(mg|mcg|g|ml|μg|κάψουλ(?:α|ες)?|δισκ(?:ίο|ία)?))?\s+(κάθε\s+(?:πρωί|μέρα|απόγευμα|βράδυ)|μία\s+φορά\s+την\s+ημέρα|δύο\s+φορές\s+την\s+ημέρα)(?:\s+(με\s+άδειο\s+στομάχι|πριν\s+το\s+φαγητό|μετά\s+το\s+φαγητό|υπογλώσσια))?[.!]?\z/i
      match = pattern.match(source.gsub(/\s+/, " ").strip)
      return [] unless match

      [entry(
        medication: match[1], schedule: greek_schedule(match[4]), effective_from: effective_from,
        effective_until: effective_until,
        dose: match[2], unit: match[3], condition: match[5]
      )]
    end

    def russian_entries(source, effective_from, effective_until)
      return [] unless RUSSIAN_VERB.match?(source)

      entries = []
      context = { schedule: nil, fasting: false }
      source.lines.each do |line|
        stripped = line.strip
        next if stripped.empty?

        stripped.split(/\s*,\s*/).each do |clause|
          clause.split(/\s+и\s+еще\s+/i).each do |part|
            detected = russian_schedule(part)
            context = {
              schedule: detected || context.fetch(:schedule),
              fasting: detected ? RUSSIAN_CONDITION.match?(part) :
                (context.fetch(:fasting) || RUSSIAN_CONDITION.match?(part))
            }
            item = russian_item(part)
            next unless item && context.fetch(:schedule)

            entries << entry(
              medication: item.fetch(:medication), schedule: context.fetch(:schedule),
              effective_from: effective_from, effective_until: effective_until,
              dose: item[:dose], unit: item[:unit],
              fasting: context.fetch(:fasting),
              administration_route: RUSSIAN_ROUTE.match?(part) ? "sublingual" : nil
            )
          end
        end
      end
      entries
    end

    def russian_schedule(text)
      RUSSIAN_TIME.each do |pattern, schedule|
        return schedule if pattern.match?(text)
      end
      nil
    end

    def russian_item(text)
      value = text.gsub(RUSSIAN_STRIP, " ").gsub(/[.:;!?]+/, " ")
                  .gsub(/\s+/, " ").strip
      return nil if value.empty?

      after = /\A(.+?)\s+(?:по\s+)?(один|одна|одно|одну|одной|два|две|\d+(?:[.,]\d+)?)\s*(#{RUSSIAN_UNIT})\z/i.match(value)
      if after
        return {
          medication: after[1], dose: quantity(after[2]), unit: russian_unit(after[3])
        }
      end
      before = /\A(?:по\s+)?(один|одна|одно|одну|одной|два|две|\d+(?:[.,]\d+)?)\s*(#{RUSSIAN_UNIT})\s+(.+)\z/i.match(value)
      if before
        return {
          medication: before[3], dose: quantity(before[1]), unit: russian_unit(before[2])
        }
      end

      { medication: value }
    end

    def entry(medication:, schedule:, effective_from:, effective_until: nil, dose: nil, unit: nil,
              condition: nil, fasting: false, administration_route: nil)
      condition_text = condition.to_s.downcase
      fasting ||= condition_text.match?(/empty\s+stomach|before\s+food|άδειο\s+στομάχι|πριν\s+το\s+φαγητό/i)
      administration_route ||= "sublingual" if
        condition_text.match?(/sublingually|under\s+the\s+tongue|υπογλώσσια/i)
      meal_relation = if condition_text.match?(/after\s+food|μετά\s+το\s+φαγητό/i)
                        "after_food"
                      elsif fasting
                        "before_food"
                      end
      legacy_details = {
        "schedule" => schedule, "fasting" => fasting,
        "meal_relation" => meal_relation
      }.reject { |_key, item| item.nil? || item == false }
      schedule_object = KnowledgeSDK::Schedule.from_legacy(
        schedule, details: [legacy_details]
      )
      value = {
        "medication" => medication.to_s.strip,
        "schedule_json" => schedule_object.to_h,
        "effective_from" => effective_from,
        "effective_until" => effective_until,
        # Safe parser diagnostics retained for Phase 13 clients.
        "parsed_schedule" => schedule, "schedule" => schedule,
        "effective_on" => effective_from
      }
      value["dose"] = dose.to_s.tr(",", ".").to_f if dose
      value["unit"] = normalized_unit(unit) if unit
      value["fasting"] = true if fasting
      value["route"] = administration_route if administration_route
      value["administration_route"] = administration_route if administration_route
      value.freeze
    end

    def quantity(value)
      QUANTITIES.fetch(value.to_s.downcase, value.to_s.tr(",", ".").to_f)
    end

    def russian_unit(value)
      unit = value.to_s.downcase
      return "capsule" if unit.start_with?("капсул")
      return "tablet" if unit.start_with?("таблет")
      return "drop" if unit.start_with?("капл")
      return "IU" if unit == "ме"

      unit
    end

    def normalized_unit(value)
      unit = value.to_s.downcase
      return "capsule" if unit.start_with?("capsule", "κάψουλ")
      return "tablet" if unit.start_with?("tablet", "δισκ")
      return "IU" if unit == "iu"
      return "mcg" if unit == "μg"

      unit
    end

    def greek_schedule(value)
      {
        "κάθε πρωί" => "every morning", "κάθε μέρα" => "every day",
        "κάθε απόγευμα" => "every afternoon", "κάθε βράδυ" => "every evening",
        "μία φορά την ημέρα" => "once daily", "δύο φορές την ημέρα" => "twice daily"
      }.fetch(value.to_s.downcase)
    end
  end

  class RoutingRegistry
    Route = Struct.new(
      :intent, :dataset, :intent_class, :builder, :writer, :row_builder,
      keyword_init: true
    )

    def initialize
      @routes = {}
    end

    # Trusted SDK plugins register construction and persistence for a classifier
    # intent. Registration is code-owned; attached Vault data is never loaded.
    def register(intent:, dataset:, intent_class:, builder:, writer:, row_builder: nil)
      intent_name = intent.to_s.strip
      raise ArgumentError, "Dataset route intent is required" if intent_name.empty?
      unless intent_name.start_with?("dataset.")
        raise ArgumentError, "Dataset route intent must use the dataset. namespace"
      end
      unless intent_class.is_a?(Class) && intent_class <= KnowledgeGraph::DatasetIntent
        raise ArgumentError, "Dataset route intent_class must inherit KnowledgeGraph::DatasetIntent"
      end
      unless builder.respond_to?(:call) && writer.respond_to?(:call)
        raise ArgumentError, "Dataset route builder and writer must respond to call"
      end

      existing = @routes[intent_name]
      if existing && (existing.dataset != Names.slug(dataset) || existing.intent_class != intent_class)
        raise DatasetConflict, "Dataset route #{intent_name} conflicts with an existing registration"
      end
      KnowledgeGraph::IntentFactory.register(intent_class)
      @routes[intent_name] = Route.new(
        intent: intent_name.freeze, dataset: Names.slug(dataset).freeze,
        intent_class: intent_class, builder: builder, writer: writer,
        row_builder: row_builder || method(:default_row_values)
      ).freeze
      self
    end

    def fetch(intent)
      @routes.fetch(intent.to_s) do
        raise InvalidRow, "no Dataset route is registered for #{intent}"
      end
    end

    def for_intent(intent)
      @routes.values.find { |route| intent.is_a?(route.intent_class) } ||
        raise(InvalidRow, "no Dataset handler is registered for #{intent.intent_type}")
    end

    def intent_classes
      @routes.values.map(&:intent_class).uniq.freeze
    end

    private

    def default_row_values(intent)
      ignored = %i[intent_id intent_type source observation_id proposal_id]
      intent.to_h.each_with_object({}) do |(key, value), result|
        result[key.to_s] = value unless ignored.include?(key.to_sym) || value.nil?
      end
    end
  end

  class << self
    def routing_registry
      @routing_registry ||= RoutingRegistry.new
    end
  end

  class IntentClassifierPlugin
    LAB_MARKERS = %w[
      ldl hdl cholesterol triglycerides glucose insulin hemoglobin haemoglobin hba1c
      ferritin iron creatinine cortisol testosterone estradiol oestradiol tsh t3 t4
      alt ast bilirubin albumin sodium potassium calcium magnesium vitamin-d b12 crp
    ].freeze
    BODY_MEASUREMENTS = %w[
      waist chest hip hips neck arm thigh calf height body-fat bodyfat
    ].freeze
    TABLE_HEADER = /\b(?:amount|currency|value|unit|marker|measurement|medication|dose|date)\b/i.freeze
    HEALTH_UNIT = /(?:\b(?:kg|lbs?|pounds?|cm|mm|bpm|mg|mcg|mg\/dL|mmol\/L|g\/dL|ng\/mL|hours?|steps?|kcal)\b|%|°[CF]|(?:кг|см|мм|мг|мкг|час[[:alpha:]]*|шаг[[:alpha:]]*|давление|вес|анализ|измерение|лекарств[[:alpha:]]*)|(?:κιλά|κιλό|ώρ[[:alpha:]]*|βήμα[[:alpha:]]*|πίεση|βάρος|εξέταση|μέτρηση|φάρμακο))/i.freeze
    FINANCE_UNIT = /(?:[$€£₽]|\b(?:USD|EUR|GBP)\b|(?:рубл|евро|доллар|сумм)|(?:ευρώ|δολάρ|ποσό))/i.freeze
    STRUCTURED_UNIT = /(?:#{HEALTH_UNIT}|#{FINANCE_UNIT})/i.freeze
    HEALTH_STATEMENT = /(?:\b(?:medication\s+schedule|lab(?:oratory)?\s+(?:result|measurement)|body\s+measurement)\b|(?:расписание\s+лекарств|лабораторн[[:alpha:]]+\s+(?:результат|измерение)|измерение\s+тела)|(?:πρόγραμμα\s+φαρμάκων|εργαστηριακ[[:alpha:]]+\s+(?:αποτέλεσμα|μέτρηση)|μέτρηση\s+σώματος))/i.freeze
    FINANCE_STATEMENT = /(?:\bfinance\s+table\b|финансов[[:alpha:]]+\s+таблиц[[:alpha:]]+|οικονομικ[[:alpha:]]+\s+πίνακ[[:alpha:]]+)/i.freeze

    class << self
      def register(classifier = KnowledgeSDK.intent_classifier)
        classifier.register(
          name: "structured-dataset-health", domain: "health", route: "dataset"
        ) do |text, context|
          new.classify_health(text, context)
        end
        classifier.register(
          name: "structured-dataset-finance", domain: "finance", route: "dataset"
        ) do |text, context|
          new.classify_finance(text, context)
        end
        classifier.register(
          name: "structured-dataset-generic", domain: "generic", route: "dataset"
        ) do |text, context|
          new.classify_generic(text, context)
        end
      end
    end

    def classify(text, context = {})
      source = text.to_s.strip
      timestamp = observed_time(context)
      medication(source, timestamp) || blood_pressure(source, timestamp) ||
        weight(source, timestamp) || blood_test(source, timestamp) ||
        body_measurement(source, timestamp) || expense(source, timestamp) ||
        structured_guard(source)
    end

    def classify_health(text, context = {})
      source = text.to_s.strip
      timestamp = observed_time(context)
      medication(source, timestamp) || blood_pressure(source, timestamp) ||
        weight(source, timestamp) || blood_test(source, timestamp) ||
        body_measurement(source, timestamp) || structured_guard(source, "health")
    end

    def classify_finance(text, context = {})
      source = text.to_s.strip
      expense(source, observed_time(context)) || structured_guard(source, "finance")
    end

    def classify_generic(text, _context = {})
      structured_guard(text.to_s.strip)
    end

    private

    def medication(source, timestamp)
      lifecycle = medication_lifecycle(source, timestamp)
      return lifecycle if lifecycle

      parser = MedicationScheduleParser.new
      if parser.administration_event?(source)
        return result(
          "dataset.structured_observation", 0.97,
          {
            "clarification_required" => true,
            "clarification_question" =>
              "This looks like a medication administration event. Should it be added to the medication log?"
          },
          "recognized a medication administration event but no named intake Intent is installed"
        )
      end

      effective_from, effective_until = schedule_dates(source, timestamp)
      parse_source = source.gsub(
        /\s+(?:starting|starts?)\s+(?:today|tomorrow|on\s+\d{4}-\d{2}-\d{2})/i, ""
      ).gsub(/\s+(?:until|ending|ends?)\s+(?:on\s+)?\d{4}-\d{2}-\d{2}/i, "")
      entries = parser.parse(
        parse_source, effective_from: effective_from, effective_until: effective_until
      )
      return nil unless entries
      if source.match?(/\b(?:starting|starts?)\b/i)
        entries = entries.map { |entry| entry.merge("replacement_requested" => true).freeze }.freeze
      end

      slots = entries.length == 1 ? entries.first.merge("entries" => entries) : {
        "effective_from" => effective_from, "effective_until" => effective_until,
        "effective_on" => effective_from, "entries" => entries
      }
      intent = entries.any? { |entry| entry["replacement_requested"] } ?
        "dataset.medication_schedule" : "dataset.medication_schedule.create"
      result(
        intent, 0.97, slots,
        "recognized a recurring medication schedule as structured Dataset data"
      )
    end

    def medication_lifecycle(source, timestamp)
      if (match = /\A\s*(?:pause|hold)\s+(.+?)(?:\s+(today|tomorrow|on\s+\d{4}-\d{2}-\d{2}))?[.!]?\s*\z/i.match(source))
        return result(
          "dataset.medication_schedule.pause", 0.98,
          { "medication" => medication_name(match[1]), "paused_on" => relative_date(match[2], timestamp) },
          "recognized a medication schedule pause"
        )
      end
      if (match = /\A\s*resume\s+(.+?)(?:\s+(today|tomorrow|on\s+\d{4}-\d{2}-\d{2}))?[.!]?\s*\z/i.match(source))
        return result(
          "dataset.medication_schedule.resume", 0.98,
          { "medication" => medication_name(match[1]), "resumed_on" => relative_date(match[2], timestamp) },
          "recognized a medication schedule resume"
        )
      end
      if (match = /\A\s*(?:stop|discontinue)\s+(?:taking\s+)?(.+?)(?:\s+(today|tomorrow|on\s+\d{4}-\d{2}-\d{2}))?[.!]?\s*\z/i.match(source))
        return result(
          "dataset.medication.stop", 0.99,
          { "medication" => medication_name(match[1]), "stopped_on" => relative_date(match[2], timestamp) },
          "recognized a medication discontinuation"
        )
      end
      dose = /\A\s*(?:change|increase|decrease|modify)\s+(.+?)\s+(?:dose\s+)?to\s+(\d+(?:\.\d+)?)\s*(mg|mcg|g|ml|capsules?|tablets?|iu)(?:\s+(today|tomorrow|on\s+\d{4}-\d{2}-\d{2}))?[.!]?\s*\z/i.match(source)
      if dose
        return result(
          "dataset.medication.dose.modify", 0.97,
          {
            "medication" => dose[1].strip, "dose" => dose[2].to_f,
            "unit" => dose[3].downcase,
            "effective_from" => relative_date(dose[4], timestamp)
          },
          "recognized a medication dose evolution"
        )
      end
      schedule = /\A\s*(?:change|modify)\s+(?:the\s+)?(?:schedule\s+for\s+)?(.+?)\s+schedule\s+to\s+(every\s+(?:morning|afternoon|evening|night|day)|once\s+daily|twice\s+daily|at\s+\d{1,2}(?::\d{2})?(?:\s*[ap]m)?)(?:\s+(today|tomorrow|on\s+\d{4}-\d{2}-\d{2}))?[.!]?\s*\z/i.match(source)
      if schedule
        return result(
          "dataset.medication.schedule.modify", 0.97,
          {
            "medication" => medication_name(schedule[1]),
            "schedule_json" => KnowledgeSDK::Schedule.from_legacy(schedule[2]).to_h,
            "effective_from" => relative_date(schedule[3], timestamp)
          },
          "recognized a medication recurrence evolution"
        )
      end
      nil
    end

    def schedule_dates(source, timestamp)
      starts = if source.match?(/\b(?:starting|starts?)\s+tomorrow\b/i)
                 timestamp.to_date + 1
               elsif (match = source.match(/\b(?:starting|starts?)\s+(?:on\s+)?(\d{4}-\d{2}-\d{2})\b/i))
                 Date.iso8601(match[1])
               else
                 timestamp.to_date
               end
      ending = source.match(/\b(?:until|ending|ends?)\s+(?:on\s+)?(\d{4}-\d{2}-\d{2})\b/i)
      [starts.iso8601, ending && Date.iso8601(ending[1]).iso8601]
    rescue ArgumentError
      [timestamp.to_date.iso8601, nil]
    end

    def relative_date(value, timestamp)
      text = value.to_s.downcase.strip
      return (timestamp.to_date + 1).iso8601 if text == "tomorrow"
      return Date.iso8601(text.delete_prefix("on ")).iso8601 if text.start_with?("on ")

      timestamp.to_date.iso8601
    rescue ArgumentError
      timestamp.to_date.iso8601
    end

    def medication_name(value)
      value.to_s.strip.sub(/\Amedication\s+/i, "").strip
    end

    def blood_pressure(source, timestamp)
      match = /\b(?:today['’]?s\s+)?(?:my\s+)?blood\s+pressure(?:\s+today)?\s+(?:was|is)\s+(\d{2,3})\s*(?:over|\/)\s*(\d{2,3})(?:\s+(?:with\s+(?:a\s+)?pulse(?:\s+of)?|pulse)\s+(\d{2,3}))?/i.match(source)
      match ||= /(?:мо[её]\s+)?(?:артериальное\s+)?давление(?:\s+сегодня)?\s*(?:было|составило|равно|:|—|-)?\s*(\d{2,3})\s*(?:\/|на)\s*(\d{2,3})(?:[,;]?\s*пульс\s*(?:был|составил|:)?\s*(\d{2,3}))?/i.match(source)
      match ||= /(?:η\s+)?(?:πίεσ(?:η|ή)\s+μου|πίεση)(?:\s+σήμερα)?\s*(?:ήταν|είναι|:|—|-)?\s*(\d{2,3})\s*(?:\/|με)\s*(\d{2,3})(?:[,;]?\s*(?:με\s+)?σφυγμ(?:ό|ος)\s*(?:ήταν|είναι|:)?\s*(\d{2,3}))?/i.match(source)
      return nil unless match

      slots = {
        "observed_at" => timestamp.iso8601, "systolic" => match[1].to_i,
        "diastolic" => match[2].to_i
      }
      slots["pulse"] = match[3].to_i if match[3]
      result(
        "dataset.blood_pressure_measurement", 0.99, slots,
        "recognized a blood pressure measurement as structured Dataset data"
      )
    end

    def weight(source, timestamp)
      match = /\b(?:today['’]?s\s+)?my\s+weight(?:\s+today)?\s+(?:was|is)\s+(\d+(?:\.\d+)?)\s*(kg|kilograms?|lbs?|pounds?)\b/i.match(source)
      match ||= /(?:мой\s+)?вес(?:\s+сегодня)?\s*(?:был|составил|равен|:|—|-)?\s*(\d+(?:[.,]\d+)?)\s*(кг|килограмм(?:а|ов)?)/i.match(source)
      match ||= /(?:το\s+)?(?:βάρος\s+μου|βάρος)(?:\s+σήμερα)?\s*(?:ήταν|είναι|:|—|-)?\s*(\d+(?:[.,]\d+)?)\s*(kg|κιλά|κιλό(?:γραμμα)?)/i.match(source)
      return nil unless match

      value = number(match[1])
      unit = match[2].downcase
      pounds = unit.start_with?("lb", "pound")
      kilograms = pounds ? (value * 0.45359237).round(6) : value
      result(
        "dataset.weight_measurement", 0.98,
        { "observed_at" => timestamp.iso8601, "weight_kg" => kilograms },
        "recognized a body-weight measurement as structured Dataset data"
      )
    end

    def blood_test(source, timestamp)
      pattern = /\b(?:today['’]?s\s+)?(?:my\s+)?(?:blood\s+test\s+(?:for\s+)?)?([a-z][a-z0-9 -]{0,40}?)\s+(?:was|is)\s+(-?\d+(?:\.\d+)?)(?:\s*(mg\/dL|mmol\/L|g\/dL|ng\/mL|pg\/mL|mIU\/L|U\/L|%))?\b/i
      match = pattern.match(source)
      if match
        marker_key = match[1].strip.downcase.tr(" ", "-")
        explicit_blood_test = source.match?(/\bblood\s+test\b/i)
        match = nil unless explicit_blood_test || LAB_MARKERS.include?(marker_key)
      end

      localized = nil
      unless match
        localized = /(?:результат\s+(?:анализа|лабораторного\s+анализа)\s*)?(лпнп|лпвп|ldl|hdl|глюкоза|гемоглобин|холестерин)\s*(?:был|составил|равен|:|—|-)?\s*(-?\d+(?:[.,]\d+)?)\s*(мг\/дл|ммоль\/л|г\/дл|нг\/мл|mg\/dL|mmol\/L|g\/dL|ng\/mL|%)?/i.match(source)
        localized ||= /(?:αποτέλεσμα\s+(?:εξέτασης|εργαστηριακής\s+εξέτασης)\s*)?(ldl|hdl|γλυκόζη|αιμοσφαιρίνη|χοληστερόλη)\s*(?:ήταν|είναι|:|—|-)?\s*(-?\d+(?:[.,]\d+)?)\s*(mg\/dL|mmol\/L|g\/dL|ng\/mL|%)?/i.match(source)
      end
      return nil unless match || localized

      if localized
        marker = normalize_lab_marker(localized[1])
        value = number(localized[2])
        unit = normalize_lab_unit(localized[3]) if localized[3]
      else
        marker_key = match[1].strip.downcase.tr(" ", "-")
        marker = marker_key.length <= 5 ? marker_key.upcase : title_word(match[1])
        value = match[2].to_f
        unit = match[3]
      end

      slots = {
        "observed_at" => timestamp.iso8601, "marker" => marker,
        "value" => value
      }
      slots["unit"] = unit if unit
      result(
        "dataset.blood_test_result", 0.97, slots,
        "recognized a laboratory measurement as structured Dataset data"
      )
    end

    def body_measurement(source, timestamp)
      pattern = /\b(?:today['’]?s\s+)?my\s+([a-z -]+?)\s+(?:measurement\s+)?(?:was|is)\s+(\d+(?:\.\d+)?)\s*(cm|mm|m|in|inches|%)\b/i
      match = pattern.match(source)
      localized = nil
      localized ||= /(?:обхват\s+)?(талии|груди|б[её]дер|шеи)|\b(рост)\b/i.match(source)
      if !match && localized
        localized = /((?:обхват\s+)?(?:талии|груди|б[её]дер|шеи)|рост)\s*(?:был|составил|равен|:|—|-)?\s*(\d+(?:[.,]\d+)?)\s*(см|мм|м|%)/i.match(source)
      end
      unless match || localized
        localized = /(?:η\s+)?(μέση|στήθος|γοφοί|λαιμός|ύψος)(?:\s+μου)?\s*(?:ήταν|είναι|:|—|-)?\s*(\d+(?:[.,]\d+)?)\s*(cm|mm|m|εκ\.?|χιλ\.?|%)/i.match(source)
      end
      return nil unless match || localized

      if localized
        measurement = normalize_body_measurement(localized[1])
        value = number(localized[2])
        unit = normalize_health_unit(localized[3])
      else
        measurement = match[1].strip.downcase.tr(" ", "-")
        return nil unless BODY_MEASUREMENTS.include?(measurement)

        value = match[2].to_f
        unit = match[3].downcase
      end

      result(
        "dataset.body_measurement", 0.96,
        {
          "observed_at" => timestamp.iso8601, "measurement" => measurement.tr("-", "_"),
          "value" => value, "unit" => unit
        },
        "recognized a physical measurement as structured Dataset data"
      )
    end

    def expense(source, timestamp)
      pattern = /\bi\s+(?:spent|paid)\s+(?:([$€£])\s*)?(\d+(?:\.\d{1,2})?)(?:\s*(USD|EUR|GBP))?\s+(?:on|for)\s+(.+?)[.!]?\z/i
      match = pattern.match(source)
      return nil unless match

      currency = match[3]&.upcase || { "$" => "USD", "€" => "EUR", "£" => "GBP" }[match[1]]
      return structured_guard(source) unless currency

      result(
        "dataset.expense", 0.96,
        {
          "occurred_on" => timestamp.to_date.iso8601, "category" => match[4].strip,
          "amount" => match[2].to_f, "currency" => currency
        },
        "recognized a financial observation as structured Dataset data"
      )
    end

    def structured_guard(source, domain = nil)
      lines = source.lines.map(&:strip).reject(&:empty?)
      table = lines.length >= 2 && TABLE_HEADER.match?(lines.first) &&
              (lines.first.include?("|") || lines.first.include?(","))
      statement_pattern = if domain == "health"
                            HEALTH_STATEMENT
                          elsif domain == "finance"
                            FINANCE_STATEMENT
                          else
                            /(?:#{HEALTH_STATEMENT}|#{FINANCE_STATEMENT})/i
                          end
      unit_pattern = if domain == "health"
                       HEALTH_UNIT
                     elsif domain == "finance"
                       FINANCE_UNIT
                     else
                       STRUCTURED_UNIT
                     end
      structured_statement = statement_pattern.match?(source)
      declarative_numeric = !source.end_with?("?") && source.match?(/\d/) && unit_pattern.match?(source)
      return nil unless table || structured_statement || declarative_numeric

      result(
        "dataset.structured_observation", 0.70,
        { "clarification_required" => true },
        "detected structured rows that require a Dataset schema or domain plugin"
      )
    end

    def observed_time(context)
      value = context["captured_at"] || context[:captured_at]
      return Time.now if value.to_s.strip.empty?

      value.is_a?(Time) ? value : Time.iso8601(value.to_s)
    rescue ArgumentError
      Time.now
    end

    def result(intent, confidence, slots, reason)
      {
        "intent" => intent, "confidence" => confidence,
        "slots" => slots, "explanation" => reason
      }
    end

    def number(value)
      value.to_s.tr(",", ".").to_f
    end

    def normalize_schedule(value, language)
      key = value.to_s.downcase
      schedules = {
        "ru" => {
          "каждое утро" => "every morning", "каждый день" => "every day",
          "каждый вечер" => "every evening", "каждую ночь" => "every night",
          "ежедневно" => "once daily", "дважды в день" => "twice daily"
        },
        "el" => {
          "κάθε πρωί" => "every morning", "κάθε μέρα" => "every day",
          "κάθε απόγευμα" => "every afternoon", "κάθε βράδυ" => "every evening",
          "μία φορά την ημέρα" => "once daily", "δύο φορές την ημέρα" => "twice daily"
        }
      }
      schedules.fetch(language, {}).fetch(key, key)
    end

    def normalize_health_unit(value)
      unit = value.to_s.downcase.delete_suffix(".")
      {
        "мг" => "mg", "мкг" => "mcg", "г" => "g", "мл" => "ml",
        "кг" => "kg", "см" => "cm", "мм" => "mm", "μg" => "mcg",
        "εκ" => "cm", "χιλ" => "mm"
      }.fetch(unit, unit)
    end

    def normalize_lab_marker(value)
      {
        "лпнп" => "LDL", "лпвп" => "HDL", "ldl" => "LDL", "hdl" => "HDL",
        "глюкоза" => "Glucose", "γλυκόζη" => "Glucose",
        "гемоглобин" => "Hemoglobin", "αιμοσφαιρίνη" => "Hemoglobin",
        "холестерин" => "Cholesterol", "χοληστερόλη" => "Cholesterol"
      }.fetch(value.to_s.downcase)
    end

    def normalize_lab_unit(value)
      {
        "мг/дл" => "mg/dL", "ммоль/л" => "mmol/L",
        "г/дл" => "g/dL", "нг/мл" => "ng/mL"
      }.fetch(value.to_s.downcase, value)
    end

    def normalize_body_measurement(value)
      {
        "талии" => "waist", "обхват талии" => "waist",
        "груди" => "chest", "обхват груди" => "chest",
        "бёдер" => "hips", "бедер" => "hips", "обхват бёдер" => "hips",
        "обхват бедер" => "hips", "шеи" => "neck", "обхват шеи" => "neck",
        "рост" => "height", "μέση" => "waist", "στήθος" => "chest",
        "γοφοί" => "hips", "λαιμός" => "neck", "ύψος" => "height"
      }.fetch(value.to_s.downcase)
    end

    def title_word(value)
      value.to_s.strip.split(/\s+/).map do |word|
        word.empty? ? word : word[0].upcase + word[1..-1].to_s.downcase
      end.join(" ")
    end
  end

  module CoreRoutes
    module_function

    def register(registry = StructuredDataset.routing_registry)
      registry.register(
        intent: "dataset.medication_schedule", dataset: "medication_schedules",
        intent_class: KnowledgeGraph::ReplaceMedicationSchedule,
        builder: ->(common, slots) { KnowledgeGraph::ReplaceMedicationSchedule.new(**common.merge(slots)) },
        writer: ->(engine, intent, provenance) {
          MedicationScheduleOperations.replace(engine, intent, provenance)
        },
        row_builder: ->(intent) { MedicationScheduleOperations.row_values(intent) }
      )
      registry.register(
        intent: "dataset.medication_schedule.create", dataset: "medication_schedules",
        intent_class: KnowledgeGraph::CreateMedicationSchedule,
        builder: ->(common, slots) { KnowledgeGraph::CreateMedicationSchedule.new(**common.merge(slots)) },
        writer: ->(engine, intent, provenance) {
          MedicationScheduleOperations.create(engine, intent, provenance)
        },
        row_builder: ->(intent) { MedicationScheduleOperations.row_values(intent) }
      )
      registry.register(
        intent: "dataset.medication_schedule.pause", dataset: "medication_schedules",
        intent_class: KnowledgeGraph::PauseMedicationSchedule,
        builder: ->(common, slots) { KnowledgeGraph::PauseMedicationSchedule.new(**common.merge(slots)) },
        writer: ->(engine, intent, provenance) {
          MedicationScheduleOperations.pause(engine, intent, provenance)
        },
        row_builder: ->(_intent) { {} }
      )
      registry.register(
        intent: "dataset.medication_schedule.resume", dataset: "medication_schedules",
        intent_class: KnowledgeGraph::ResumeMedicationSchedule,
        builder: ->(common, slots) { KnowledgeGraph::ResumeMedicationSchedule.new(**common.merge(slots)) },
        writer: ->(engine, intent, provenance) {
          MedicationScheduleOperations.resume(engine, intent, provenance)
        },
        row_builder: ->(_intent) { {} }
      )
      registry.register(
        intent: "dataset.medication.stop", dataset: "medication_schedules",
        intent_class: KnowledgeGraph::StopMedication,
        builder: ->(common, slots) { KnowledgeGraph::StopMedication.new(**common.merge(slots)) },
        writer: ->(engine, intent, provenance) {
          MedicationScheduleOperations.stop(engine, intent, provenance)
        },
        row_builder: ->(_intent) { {} }
      )
      registry.register(
        intent: "dataset.medication.dose.modify", dataset: "medication_schedules",
        intent_class: KnowledgeGraph::ModifyMedicationDose,
        builder: ->(common, slots) { KnowledgeGraph::ModifyMedicationDose.new(**common.merge(slots)) },
        writer: ->(engine, intent, provenance) {
          MedicationScheduleOperations.modify_dose(engine, intent, provenance)
        },
        row_builder: ->(_intent) { {} }
      )
      registry.register(
        intent: "dataset.medication.schedule.modify", dataset: "medication_schedules",
        intent_class: KnowledgeGraph::ModifyMedicationSchedule,
        builder: ->(common, slots) { KnowledgeGraph::ModifyMedicationSchedule.new(**common.merge(slots)) },
        writer: ->(engine, intent, provenance) {
          MedicationScheduleOperations.modify_schedule(engine, intent, provenance)
        },
        row_builder: ->(_intent) { {} }
      )
      registry.register(
        intent: "dataset.blood_pressure_measurement", dataset: "blood_pressure",
        intent_class: KnowledgeGraph::InsertBloodPressureMeasurement,
        builder: ->(common, slots) { KnowledgeGraph::InsertBloodPressureMeasurement.new(**common.merge(slots)) },
        writer: lambda do |engine, intent, provenance|
          engine.insert(
            "blood_pressure",
            compact(
              observed_at: intent.observed_at, systolic: intent.systolic,
              diastolic: intent.diastolic, pulse: intent.pulse
            ),
            provenance
          )
        end
      )
      registry.register(
        intent: "dataset.weight_measurement", dataset: "weight",
        intent_class: KnowledgeGraph::InsertWeightMeasurement,
        builder: ->(common, slots) { KnowledgeGraph::InsertWeightMeasurement.new(**common.merge(slots)) },
        writer: lambda do |engine, intent, provenance|
          engine.insert(
            "weight", { observed_at: intent.observed_at, weight_kg: intent.weight_kg }, provenance
          )
        end
      )
      registry.register(
        intent: "dataset.blood_test_result", dataset: "blood_tests",
        intent_class: KnowledgeGraph::InsertBloodTestResult,
        builder: ->(common, slots) { KnowledgeGraph::InsertBloodTestResult.new(**common.merge(slots)) },
        writer: lambda do |engine, intent, provenance|
          engine.insert(
            "blood_tests", blood_test_values(intent), provenance
          )
        end,
        row_builder: ->(intent) { blood_test_values(intent) }
      )
      registry.register(
        intent: "dataset.body_measurement", dataset: "body_measurements",
        intent_class: KnowledgeGraph::InsertBodyMeasurement,
        builder: ->(common, slots) { KnowledgeGraph::InsertBodyMeasurement.new(**common.merge(slots)) },
        writer: lambda do |engine, intent, provenance|
          engine.insert(
            "body_measurements",
            {
              observed_at: intent.observed_at, measurement: intent.measurement,
              value: intent.value, unit: intent.unit
            },
            provenance
          )
        end
      )
      registry.register(
        intent: "dataset.expense", dataset: "expenses",
        intent_class: KnowledgeGraph::InsertExpense,
        builder: ->(common, slots) { KnowledgeGraph::InsertExpense.new(**common.merge(slots)) },
        writer: lambda do |engine, intent, provenance|
          engine.insert(
            "expenses",
            compact(
              occurred_on: intent.occurred_on, category: intent.category,
              amount: intent.amount, currency: intent.currency, merchant: intent.merchant
            ),
            provenance
          )
        end
      )
      registry
    end

    def compact(values)
      values.reject { |_key, value| value.nil? }
    end

    def blood_test_values(intent)
      observed = Time.iso8601(intent.observed_at.to_s)
      compact(
        test_date: observed.to_date.iso8601, analyte: intent.marker,
        value: intent.value, unit: intent.unit || "unspecified",
        observed_at: observed.iso8601, marker: intent.marker
      )
    rescue ArgumentError
      compact(
        test_date: intent.observed_at.to_s[0, 10], analyte: intent.marker,
        value: intent.value, unit: intent.unit || "unspecified",
        observed_at: intent.observed_at, marker: intent.marker
      )
    end
  end

  class DatasetProposalBuilder
    PIPELINE_VERSION = "dataset-routing-v1".freeze
    PROMPT_VERSION = "intent-classifier-v1".freeze

    def initialize(vault_root:, proposal_store:, classifier:, event_bus: nil, clock: nil,
                   routing_registry: StructuredDataset.routing_registry,
                   template_registry: StructuredDataset.template_registry)
      @vault_root = vault_root
      @proposal_store = proposal_store
      @classifier = classifier
      @event_bus = event_bus
      @clock = clock || -> { Time.now }
      @routing_registry = routing_registry
      @template_registry = template_registry
    end

    def create(arguments)
      document = source_document(arguments)
      classifier_context = {
        "captured_at" => document.captured_at, "source_type" => document.source_type,
        "source_uri" => document.source_uri, "source_filename" => document.title,
        "title" => document.title, "language" => document.language
      }.reject { |_key, value| value.nil? }
      classification = @classifier.classify(document.content, classifier_context)
      observation = TemplateObservation.from_document(document)
      selection = @template_registry.select(observation)
      if selection && template_import_candidate?(document, classification)
        rows = begin
          selection.template.parse(observation)
        rescue InvalidRow, ImportError
          []
        end
        return create_template_import(arguments, document, selection, rows) unless rows.empty?
        if classification && classification.intent == "dataset.template_import"
          return template_parse_clarification(selection)
        end
      end
      unless classification && classification.route == "dataset"
        raise InvalidRow, "message is not a structured Dataset observation"
      end
      if classification.slots["clarification_required"]
        return {
          "status" => "clarification_required", "classification" => classification.to_h,
          "question" => classification.slots["clarification_question"] ||
            "Which Dataset schema should receive these structured rows?",
          "executable" => false, "approval_required" => true, "planned_intent_count" => 0
        }
      end

      proposal_id = KnowledgeExtraction::Support.stable_id(
        "proposal", document.source_id, classification.intent,
        KnowledgeExtraction::Support.canonical_json(classification.slots),
        dataset_state_signature(classification.intent)
      )
      route = @routing_registry.fetch(classification.intent)
      slot_sets = intent_slot_sets(classification).each_with_index.map do |slots, index|
        enrich_medication_slots(route, slots, document, index)
      end
      intents = slot_sets.map do |slots|
        build_intent(route, classification, document, proposal_id, arguments, slots)
      end
      evidence = KnowledgeExtraction::EvidenceSpan.new(
        source_id: document.source_id, start_offset: 0,
        end_offset: [document.content.length, 2_000].min,
        excerpt: document.content[0...[document.content.length, 2_000].min]
      )
      subject = KnowledgeExtraction::EntityMention.new(
        entity_type: "person", display_name: "Dataset owner", evidence: [evidence]
      )
      fact = KnowledgeExtraction::ExtractedFact.new(
        fact_type: "dataset_observation", subject: subject,
        predicate: route.dataset,
        object: KnowledgeExtraction::ScalarValue.new(
          value: classification.slots, value_type: "json",
          original_expression: evidence.excerpt, normalized_value: classification.slots,
          normalization_confidence: classification.confidence
        ),
        confidence: classification.confidence, evidence: [evidence],
        extraction_method: "intent_classifier"
      )
      dataset_id = KnowledgeExtraction::Support.deterministic_ulid(
        "dataset", document.captured_at || @clock.call, document.source_id, route.dataset
      )
      evolution = AutonomousRegistry.new(
        vault_root: @vault_root, engine: evolution_engine, clock: @clock
      ).plan(
        dataset: route.dataset, values: route.row_builder.call(intents.first),
        source: arguments["origin_source"] || document.source_type,
        proposal_id: proposal_id, dataset_id: dataset_id
      )
      provenance = {
        source_id: document.source_id, source_type: document.source_type,
        captured_at: document.captured_at&.iso8601
      }
      prerequisite = evolution.prerequisite? ? KnowledgeExtraction::PlannedIntent.new(
        planned_intent_id: KnowledgeExtraction::Support.stable_id(
          "planned", proposal_id, evolution.intent.intent_type
        ),
        intent: evolution.intent, fact_ids: [fact.fact_id], evidence_ids: [evidence.evidence_id],
        planning_confidence: classification.confidence, risk: "medium",
        approval_requirement: "human_review", blocked_reasons: [], provenance: provenance
      ) : nil
      planned = intents.each_with_index.map do |intent, index|
        KnowledgeExtraction::PlannedIntent.new(
          planned_intent_id: KnowledgeExtraction::Support.stable_id(
            "planned", proposal_id, intent.intent_type, index,
            KnowledgeExtraction::Support.canonical_json(slot_sets.fetch(index))
          ),
          intent: intent, fact_ids: [fact.fact_id], evidence_ids: [evidence.evidence_id],
          planning_confidence: classification.confidence, risk: "medium",
          approval_requirement: "human_review", blocked_reasons: [],
          dependencies: prerequisite ? [prerequisite.planned_intent_id] : [], provenance: provenance
        )
      end
      planned_intents = [prerequisite, *planned].compact
      warnings = evolution_warning(evolution)
      proposal = KnowledgeExtraction::ExtractionProposal.new(
        proposal_id: proposal_id, source: document,
        summary: proposal_summary(
          route.dataset, evolution, parsed_entry_count(classification)
        ),
        facts: [fact], entity_mentions: [subject], resolution_decisions: [],
        planned_intents: planned_intents, warnings: warnings, conflicts: [],
        required_approvals: {
          total: planned_intents.length, blocked: 0,
          by_risk: { low: 0, medium: planned_intents.length, high: 0 }
        },
        rejected_items: [],
        model_metadata: {
          "provider" => "intent-classifier", "intent" => classification.intent,
          "confidence" => classification.confidence,
          "dataset_evolution" => evolution.to_h
        },
        prompt_version: PROMPT_VERSION, pipeline_version: PIPELINE_VERSION,
        created_at: document.captured_at || @clock.call, status: "awaiting_approval",
        ingestion_state: @proposal_store.classify_source(document)
      )
      @proposal_store.save(proposal)
      @proposal_store.record_source(document, proposal.proposal_id)
      KnowledgeExtraction::ProposalValidator.new.validate!(@proposal_store.load(proposal.proposal_id))
      publish_proposal(proposal, classification, arguments)
      {
        "status" => proposal.status, "proposal_id" => proposal.proposal_id,
        "intent" => classification.intent,
        "proposal" => {
          "id" => proposal.proposal_id, "type" => "dataset_update", "status" => proposal.status
        },
        "classification" => classification.to_h,
        "planned_intent_count" => proposal.planned_intents.length,
        "parsed_entry_count" => parsed_entry_count(classification),
        "approval_required" => true, "executable" => false,
        "warnings" => proposal.warnings, "dataset_evolution" => evolution.to_h
      }.merge(
        "explainability" => dataset_explainability(classification, planned_intents)
      ).reject { |_key, value| value.nil? }
    end

    private

    def template_import_candidate?(document, classification)
      return true if classification && classification.intent == "dataset.template_import"
      return true if %w[pdf-text ocr-text image-ocr csv excel].include?(document.source_type)

      document.content.lines.length >= 3 && TemplateParsers.headers(document.content).length >= 2
    end

    def template_parse_clarification(selection)
      {
        "status" => "clarification_required",
        "classification" => template_classification(selection).to_h,
        "question" => "I recognised this as #{selection.template.display_name}, but could not identify complete observations. Please provide a clearer extracted table or text rendition.",
        "executable" => false, "approval_required" => true,
        "planned_intent_count" => 0, "template_selection" => selection.to_h
      }
    end

    def create_template_import(arguments, document, selection, rows)
      template = selection.template
      classification = template_classification(selection)
      state_signature = dataset_state_signature_for(template.definition.slug)
      proposal_id = KnowledgeExtraction::Support.stable_id(
        "proposal", document.source_id, "dataset.template_import", template.digest,
        KnowledgeExtraction::Support.canonical_json(rows.map(&:values)), state_signature
      )
      evidences = rows.map do |row|
        KnowledgeExtraction::EvidenceSpan.new(
          source_id: document.source_id, start_offset: row.start_offset,
          end_offset: row.end_offset, excerpt: row.excerpt, page: row.page
        )
      end
      subject = KnowledgeExtraction::EntityMention.new(
        entity_type: "person", display_name: "Dataset owner", evidence: [evidences.first]
      )
      fact = KnowledgeExtraction::ExtractedFact.new(
        fact_type: "dataset_observation", subject: subject,
        predicate: template.definition.slug,
        object: KnowledgeExtraction::ScalarValue.new(
          value: { "template" => template.id, "observations" => rows.length },
          value_type: "json", original_expression: evidences.first.excerpt,
          normalized_value: { "template" => template.id, "observations" => rows.length },
          normalization_confidence: selection.confidence
        ),
        confidence: selection.confidence, evidence: evidences,
        extraction_method: "dataset-template:#{template.plugin}"
      )
      dataset_id = KnowledgeExtraction::Support.deterministic_ulid(
        "dataset", document.captured_at || @clock.call, document.source_id, template.definition.slug
      )
      evolution = AutonomousRegistry.new(
        vault_root: @vault_root, engine: evolution_engine, clock: @clock
      ).plan(
        dataset: template.definition.slug, values: rows.first.values,
        schema: template.definition, source: arguments["origin_source"] || document.source_type,
        proposal_id: proposal_id, dataset_id: dataset_id, template: template
      )
      base_provenance = {
        source_id: document.source_id, source_type: document.source_type,
        source_uri: document.source_uri, source_filename: document.title,
        captured_at: document.captured_at&.iso8601
      }.reject { |_key, value| value.nil? }
      prerequisite = evolution.prerequisite? ? KnowledgeExtraction::PlannedIntent.new(
        planned_intent_id: KnowledgeExtraction::Support.stable_id(
          "planned", proposal_id, evolution.intent.intent_type
        ),
        intent: evolution.intent, fact_ids: [fact.fact_id],
        evidence_ids: evidences.map(&:evidence_id),
        planning_confidence: selection.confidence, risk: "medium",
        approval_requirement: "human_review", blocked_reasons: [], provenance: base_provenance
      ) : nil
      planned_rows = rows.each_with_index.map do |row, index|
        evidence = evidences.fetch(index)
        intent = KnowledgeGraph::InsertDatasetRow.new(
          dataset: template.definition.slug, values: row.values,
          source: arguments["origin_source"] || document.source_type,
          observation_id: arguments["observation_id"] || document.source_id,
          proposal_id: proposal_id,
          evidence_id: evidence.evidence_id, source_uri: document.source_uri,
          source_filename: document.title, source_page: row.page,
          source_span: "#{row.start_offset}:#{row.end_offset}",
          intent_id: KnowledgeExtraction::Support.stable_id(
            "intent", document.source_id, template.id, template.version, index,
            KnowledgeExtraction::Support.canonical_json(row.values), evidence.evidence_id
          )
        )
        row_provenance = base_provenance.merge(
          evidence_id: evidence.evidence_id, source_page: row.page,
          source_span: "#{row.start_offset}:#{row.end_offset}"
        )
        KnowledgeExtraction::PlannedIntent.new(
          planned_intent_id: KnowledgeExtraction::Support.stable_id(
            "planned", proposal_id, intent.intent_type, index, intent.intent_id
          ),
          intent: intent, fact_ids: [fact.fact_id], evidence_ids: [evidence.evidence_id],
          planning_confidence: selection.confidence, risk: "medium",
          approval_requirement: "human_review", blocked_reasons: [],
          dependencies: prerequisite ? [prerequisite.planned_intent_id] : [],
          provenance: row_provenance
        )
      end
      planned_intents = [prerequisite, *planned_rows].compact
      proposal = KnowledgeExtraction::ExtractionProposal.new(
        proposal_id: proposal_id, source: document,
        summary: template_proposal_summary(selection, evolution, rows.length),
        facts: [fact], entity_mentions: [subject], resolution_decisions: [],
        planned_intents: planned_intents, warnings: evolution_warning(evolution), conflicts: [],
        required_approvals: {
          total: planned_intents.length, blocked: 0,
          by_risk: { low: 0, medium: planned_intents.length, high: 0 }
        },
        rejected_items: [],
        model_metadata: {
          "provider" => "dataset-template-registry", "intent" => classification.intent,
          "confidence" => selection.confidence, "template_selection" => selection.to_h,
          "dataset_evolution" => evolution.to_h, "parsed_observations" => rows.length
        },
        prompt_version: "dataset-template-selection-v1",
        pipeline_version: "dataset-template-provisioning-v1",
        created_at: document.captured_at || @clock.call, status: "awaiting_approval",
        ingestion_state: @proposal_store.classify_source(document)
      )
      @proposal_store.save(proposal)
      @proposal_store.record_source(document, proposal.proposal_id)
      KnowledgeExtraction::ProposalValidator.new.validate!(@proposal_store.load(proposal.proposal_id))
      publish_proposal(proposal, classification, arguments)
      confirmation = template_confirmation(selection, evolution, rows.length)
      {
        "status" => proposal.status, "proposal_id" => proposal.proposal_id,
        "intent" => classification.intent,
        "proposal" => {
          "id" => proposal.proposal_id, "type" => "dataset_update", "status" => proposal.status
        },
        "classification" => classification.to_h,
        "planned_intent_count" => planned_intents.length,
        "parsed_entry_count" => rows.length,
        "approval_required" => true, "executable" => false,
        "warnings" => proposal.warnings, "dataset_evolution" => evolution.to_h,
        "template_selection" => selection.to_h,
        "planned_dataset" => {
          "name" => template.display_name,
          "action" => evolution.kind == "current" ? "use_existing" : evolution.kind
        },
        "planned_import" => {
          "observation_count" => rows.length, "source_type" => document.source_type,
          "source_filename" => document.title
        }.reject { |_key, value| value.nil? },
        "confirmation" => confirmation,
        "explainability" => {
          "template" => template.id, "selected_template" => template.id,
          "template_version" => template.version,
          "confidence" => selection.confidence, "reason" => selection.reason,
          "dataset_evolution" => evolution.to_h,
          "planned_dataset" => template.display_name,
          "planned_import_count" => rows.length,
          "generated_intents" => planned_intents.map { |item| item.intent.intent_type }
        }
      }
    end

    def template_classification(selection)
      KnowledgeSDK::IntentClassification.new(
        intent: "dataset.template_import", confidence: selection.confidence,
        route: "dataset", domain: selection.template.domain,
        explanation: selection.reason, slots: selection.to_h
      )
    end

    def template_proposal_summary(selection, evolution, count)
      action = evolution.kind == "current" ? "use the existing Dataset" : "provision the Dataset"
      "Recognised #{selection.template.display_name} and planned to #{action} before importing #{count} observation#{count == 1 ? '' : 's'}."
    end

    def template_confirmation(selection, evolution, count)
      lines = ["I recognised this as #{selection.template.display_name}."]
      if evolution.kind == "create"
        lines << "A new #{selection.template.display_name} collection will be created."
      elsif %w[schema_upgrade schema_migration].include?(evolution.kind)
        lines << "The existing #{selection.template.display_name} collection will be safely updated."
      end
      noun = selection.template.id == "blood_tests" ? "laboratory measurement" : "observation"
      lines << "#{count} #{noun}#{count == 1 ? '' : 's'} will be imported."
      lines << "Proceed?"
      lines.join("\n\n")
    end

    def source_document(arguments)
      envelope_metadata = {
        "observation_id" => arguments["observation_id"],
        "observation_source" => arguments["origin_source"],
        "conversation_id" => arguments["conversation_id"],
        "message_id" => arguments["message_id"], "sender" => arguments["sender"],
        "sensitivity" => arguments.fetch("sensitivity", "private")
      }.reject { |_key, value| value.nil? }
      KnowledgeExtraction::SourceDocument.new(
        source_type: arguments.fetch("source_type"), content: arguments.fetch("content"),
        language: arguments.fetch("language", "und"), captured_at: arguments["captured_at"],
        external_id: arguments["external_id"], source_uri: arguments["source_uri"],
        title: arguments["title"] || arguments["source_filename"],
        author: arguments["sender"], metadata: envelope_metadata
      )
    end

    def build_intent(route, classification, document, proposal_id, arguments, slots)
      common = {
        source: arguments["origin_source"] || document.source_type,
        observation_id: arguments["observation_id"] || document.source_id,
        proposal_id: proposal_id,
        intent_id: KnowledgeExtraction::Support.stable_id(
          "intent", document.source_id, classification.intent,
          KnowledgeExtraction::Support.canonical_json(slots)
        )
      }
      route.builder.call(common, slots.transform_keys(&:to_sym))
    end

    def intent_slot_sets(classification)
      entries = Array(classification.slots["entries"])
      return [classification.slots.reject { |key, _value| key == "entries" }] if entries.empty?

      if entries.any? { |entry| entry["replacement_requested"] }
        return entries.group_by { |entry| entry.fetch("medication").downcase }.map do |_key, group|
          first = group.first
          schedules = group.map { |entry| entry.fetch("schedule_json") }
          combined = schedules.first.merge(
            "times" => schedules.flat_map { |schedule| Array(schedule["times"]) }.uniq
          )
          slots = {
            "medication" => first.fetch("medication"),
            "schedule_json" => combined,
            "effective_from" => first.fetch("effective_from"),
            "effective_until" => first["effective_until"],
            "replace_all" => true
          }
          %w[dose unit route reason prescribing_provider notes].each do |key|
            values = group.map { |entry| entry[key] }.uniq
            slots[key] = values.first if values.length == 1 && !values.first.nil?
          end
          slots.reject { |_key, value| value.nil? }
        end
      end

      entries.map do |entry|
        %w[
          medication schedule_json effective_from effective_until dose unit route
          reason prescribing_provider notes
        ].each_with_object({}) do |key, slots|
          slots[key] = entry[key] if entry.key?(key) && !entry[key].nil?
        end
      end
    end

    def enrich_medication_slots(route, slots, document, index)
      klass = route.intent_class
      medication_classes = [
        KnowledgeGraph::CreateMedicationSchedule, KnowledgeGraph::ReplaceMedicationSchedule,
        KnowledgeGraph::PauseMedicationSchedule, KnowledgeGraph::ResumeMedicationSchedule,
        KnowledgeGraph::ModifyMedicationDose, KnowledgeGraph::ModifyMedicationSchedule
      ]
      return slots unless medication_classes.include?(klass)

      identifier = KnowledgeExtraction::Support.deterministic_ulid(
        "medschedule", document.captured_at || @clock.call,
        document.source_id, route.intent, index,
        KnowledgeExtraction::Support.canonical_json(slots)
      )
      enriched = slots.dup
      if klass == KnowledgeGraph::CreateMedicationSchedule
        enriched["schedule_id"] ||= identifier
      else
        enriched["replacement_schedule_id"] ||= identifier
      end
      enriched
    end

    def dataset_explainability(classification, planned_intents)
      entries = Array(classification.slots["entries"])
      return {
        "generated_intents" => planned_intents.map { |item| item.intent.intent_type }
      } if entries.empty?

      {
        "parsed_schedule" => entries.map { |entry| entry["parsed_schedule"] }.compact,
        "schedule_object" => entries.map { |entry| entry["schedule_json"] }.compact,
        "effective_interval" => entries.map do |entry|
          {
            "effective_from" => entry["effective_from"],
            "effective_until" => entry["effective_until"]
          }
        end,
        "generated_intents" => planned_intents.map { |item| item.intent.intent_type }
      }
    end

    def parsed_entry_count(classification)
      entries = Array(classification.slots["entries"])
      entries.empty? ? 1 : entries.length
    end

    def dataset_state_signature(intent_name)
      route = @routing_registry.fetch(intent_name)
      description = evolution_engine.describe(route.dataset)
      KnowledgeExtraction::Support.canonical_json(
        "dataset_id" => description.fetch("dataset_id"),
        "schema_version" => description.fetch("schema_version"),
        "columns" => description.fetch("columns")
      )
    rescue DatasetNotFound
      "missing:#{@routing_registry.fetch(intent_name).dataset}"
    end


    def dataset_state_signature_for(dataset)
      description = evolution_engine.describe(dataset)
      KnowledgeExtraction::Support.canonical_json(
        "dataset_id" => description.fetch("dataset_id"),
        "schema_version" => description.fetch("schema_version"),
        "columns" => description.fetch("columns")
      )
    rescue DatasetNotFound
      "missing:#{dataset}"
    end

    def evolution_engine
      @evolution_engine ||= Engine.new(vault_root: @vault_root, clock: @clock)
    end

    def evolution_warning(evolution)
      case evolution.kind
      when "create"
        ["Dataset #{evolution.dataset} is not registered; approval will create it before the observation is written."]
      when "schema_upgrade"
        ["Dataset #{evolution.dataset} needs additive columns #{evolution.added_columns.join(', ')}; approval will upgrade it before retrying the observation."]
      when "schema_migration"
        ["Dataset #{evolution.dataset} uses the legacy schedule schema; approval will copy, verify, and migrate it before retrying the observation."]
      else
        []
      end
    end

    def proposal_summary(dataset, evolution, count)
      noun = count == 1 ? "observation" : "schedule entries"
      case evolution.kind
      when "create"
        "Classified #{count} structured #{noun} and planned automatic registration of #{dataset}."
      when "schema_upgrade"
        "Classified #{count} structured #{noun} and planned an additive schema upgrade for #{dataset}."
      when "schema_migration"
        "Classified #{count} structured #{noun} and planned a verified schema migration for #{dataset}."
      else
        "Classified #{count} structured #{noun} for #{dataset}."
      end
    end

    def publish_proposal(proposal, classification, arguments)
      return unless @event_bus

      correlation_id = arguments["observation_id"] || proposal.proposal_id
      @event_bus.publish(
        type: "ProposalCreated", source: "dataset-intent-classifier",
        payload: {
          "observation_id" => arguments["observation_id"],
          "proposal_id" => proposal.proposal_id, "status" => proposal.status,
          "intent" => classification.intent, "executable" => false
        }.reject { |_key, value| value.nil? },
        correlation_id: correlation_id
      )
    rescue KnowledgeOrchestration::Error
      nil
    end
  end

  class IntentHandler
    def initialize(dataset_engine:, proposal_id:, approval: nil,
                   routing_registry: StructuredDataset.routing_registry)
      @dataset_engine = dataset_engine
      @proposal_id = proposal_id
      @approval = approval
      @routing_registry = routing_registry
    end

    def attach(engine)
      supported.each { |intent_class| engine.register(intent_class, method(:execute)) }
      engine
    end

    def self.supports?(intent)
      intent.is_a?(KnowledgeGraph::InsertDatasetRow) || lifecycle_intent?(intent) ||
        StructuredDataset.routing_registry.intent_classes.any? { |intent_class| intent.is_a?(intent_class) }
    end

    def self.lifecycle_intent?(intent)
      intent.is_a?(KnowledgeGraph::CreateDataset) ||
        intent.is_a?(KnowledgeGraph::UpgradeDatasetSchema)
    end

    def execute(intent, context = nil)
      unless @approval && @approval["approval_id"] && @approval["actor_id"]
        raise KnowledgeGraph::ApprovalRequired, "Dataset Intents require an exact approved proposal"
      end

      raise KnowledgeGraph::TransactionError, "Dataset Intent execution requires an Engine context" unless context

      return execute_lifecycle(intent, context) if self.class.lifecycle_intent?(intent)

      dataset = dataset_for(intent)
      dataset_id = @dataset_engine.describe(dataset).fetch("dataset_id")
      context.defer { execute_row(intent, dataset, dataset_id) }
      KnowledgeGraph::Result.new(intent_type: intent.intent_type, entity_ids: [dataset_id])
    end

    private

    def execute_lifecycle(intent, context)
      dataset_id = if intent.is_a?(KnowledgeGraph::CreateDataset)
                     intent.dataset_id
                   else
                     @dataset_engine.describe(intent.dataset).fetch("dataset_id")
                   end
      context.defer { execute_lifecycle_change(intent, dataset_id) }
      KnowledgeGraph::Result.new(intent_type: intent.intent_type, entity_ids: [dataset_id])
    end

    def execute_lifecycle_change(intent, dataset_id)
      result = if intent.is_a?(KnowledgeGraph::CreateDataset)
                 create_dataset(intent)
               else
                 upgrade_schema(intent)
               end
      KnowledgeGraph::Result.new(
        intent_type: intent.intent_type, entity_ids: [dataset_id],
        replayed: result.fetch("replayed", false),
        value: {
          "dataset_id" => dataset_id, "schema_version" => result["schema_version"],
          "dataset_activity_id" => result["dataset_activity_id"],
          "added_columns" => intent.respond_to?(:added_columns) ? intent.added_columns : nil
        }.reject { |_key, value| value.nil? }
      )
    end

    def create_dataset(intent)
      @dataset_engine.create(
        intent.dataset, schema: intent.schema, owner_id: intent.owner_id,
        dataset_id: intent.dataset_id, provenance: provenance(intent),
        template_id: intent.template_id, template_version: intent.template_version,
        template_digest: intent.template_digest
      )
    rescue DatasetConflict
      existing = @dataset_engine.describe(intent.dataset)
      unless existing.fetch("dataset_id") == intent.dataset_id &&
             existing.fetch("columns") == Definition.from_h(intent.schema).columns.map(&:to_h)
        raise
      end

      existing.merge("replayed" => true)
    end

    def upgrade_schema(intent)
      current = @dataset_engine.describe(intent.dataset)
      target = Definition.from_h(intent.schema)
      if current.fetch("schema_version").to_i > intent.from_version.to_i
        return current.merge("replayed" => true) if current.fetch("columns") == target.columns.map(&:to_h)

        raise MigrationError, "Dataset schema changed after this proposal was created"
      end
      unless current.fetch("schema_version").to_i == intent.from_version.to_i
        raise MigrationError, "Dataset schema version does not match the approved proposal"
      end

      if intent.migration_id == MedicationScheduleSchemaMigration::ID
        return @dataset_engine.migrate_medication_schedules(
          intent.dataset, intent.schema, provenance(intent)
        )
      end
      if intent.migration_id
        raise MigrationError, "unknown approved Dataset migration #{intent.migration_id.inspect}"
      end

      @dataset_engine.migrate(intent.dataset, intent.schema, provenance(intent))
    end

    def execute_row(intent, dataset, dataset_id)
      row, dataset = if intent.is_a?(KnowledgeGraph::InsertDatasetRow)
                       [@dataset_engine.insert(intent.dataset, intent.values, provenance(intent)), intent.dataset]
                     else
                       route = @routing_registry.for_intent(intent)
                       [route.writer.call(@dataset_engine, intent, provenance(intent)), route.dataset]
                     end
      KnowledgeGraph::Result.new(
        intent_type: intent.intent_type, entity_ids: [dataset_id], replayed: row.fetch("replayed", false),
        value: {
          "dataset_id" => dataset_id, "row_id" => row["row_id"],
          "updated_rows" => row["updated"],
          "dataset_activity_id" => row["dataset_activity_id"]
        }.reject { |_key, value| value.nil? }
      )
    end

    def dataset_for(intent)
      return intent.dataset if intent.is_a?(KnowledgeGraph::InsertDatasetRow)

      @routing_registry.for_intent(intent).dataset
    end

    def supported
      [
        KnowledgeGraph::InsertDatasetRow, KnowledgeGraph::CreateDataset,
        KnowledgeGraph::UpgradeDatasetSchema, *@routing_registry.intent_classes
      ].uniq
    end

    def provenance(intent)
      values = {
        source: intent.source,
        observation_id: intent.respond_to?(:observation_id) ? intent.observation_id : nil,
        proposal_id: @proposal_id || (intent.respond_to?(:proposal_id) && intent.proposal_id),
        approval_id: @approval && @approval["approval_id"],
        created_by: @approval && @approval["actor_id"] || "proposal-engine",
        intent_id: intent.intent_id
      }
      %i[evidence_id source_uri source_filename source_page source_span].each do |field|
        values[field] = intent.public_send(field) if intent.respond_to?(field)
      end
      values.reject { |_key, value| value.nil? }
    end
  end
end

StructuredDataset::CoreRoutes.register
StructuredDataset::IntentClassifierPlugin.register
