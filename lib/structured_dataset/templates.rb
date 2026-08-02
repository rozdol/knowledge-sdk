# frozen_string_literal: true

require "csv"
require "date"
require "digest"
require "json"
require "time"

module StructuredDataset
  class TemplateObservation
    attr_reader :source_type, :content, :captured_at, :source_uri, :source_filename,
                :title, :language, :source_id

    def initialize(source_type:, content:, captured_at: nil, source_uri: nil,
                   source_filename: nil, title: nil, language: "und", source_id: nil)
      @source_type = source_type.to_s.freeze
      @content = content.to_s.freeze
      raise InvalidRow, "template observation content is required" if @content.strip.empty?

      @captured_at = parse_time(captured_at)
      @source_uri = optional(source_uri)
      @title = optional(title)
      @source_filename = optional(source_filename) || filename_from(@title || @source_uri)
      @language = language.to_s.freeze
      @source_id = optional(source_id)
      freeze
    end

    def self.from_document(document)
      new(
        source_type: document.source_type, content: document.content,
        captured_at: document.captured_at, source_uri: document.source_uri,
        source_filename: document.title, title: document.title,
        language: document.language, source_id: document.source_id
      )
    end

    def page_for(offset)
      content[0...offset.to_i].to_s.count("\f") + 1
    end

    private

    def parse_time(value)
      return value if value.is_a?(Time)
      return nil if value.to_s.strip.empty?

      Time.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end

    def optional(value)
      text = value.to_s.strip
      text.empty? ? nil : text.freeze
    end

    def filename_from(value)
      text = value.to_s.split(/[?#]/, 2).first.to_s
      name = File.basename(text)
      name == "." || name == "/" || name.empty? ? nil : name.freeze
    end
  end

  class ParsedTemplateRow
    attr_reader :values, :excerpt, :start_offset, :end_offset, :page

    def initialize(values:, excerpt:, start_offset:, end_offset:, page: nil)
      @values = immutable_hash(values)
      @excerpt = excerpt.to_s[0, 2_000].freeze
      @start_offset = Integer(start_offset)
      @end_offset = Integer(end_offset)
      @page = page && Integer(page)
      raise InvalidRow, "parsed template row needs a non-empty evidence span" if
        @excerpt.empty? || @end_offset <= @start_offset
      freeze
    end

    private

    def immutable_hash(value)
      value.each_with_object({}) do |(key, item), result|
        result[key.to_s.freeze] = immutable(item)
      end.freeze
    end

    def immutable(value)
      case value
      when Hash then immutable_hash(value)
      when Array then value.map { |item| immutable(item) }.freeze
      when String then value.dup.freeze
      else value.freeze
      end
    end
  end

  class DatasetTemplate
    DOMAINS = %w[health finance trading crm generic].freeze
    attr_reader :id, :version, :domain, :definition, :plugin, :keywords,
                :header_aliases, :recommended_analyzers, :visualizations,
                :privacy_level, :adapters, :validation_rules,
                :recommendation_rules, :analysis_semantics, :digest

    def initialize(id:, version:, domain:, definition:, parser:, plugin:,
                   keywords: [], header_aliases: {}, recommended_analyzers: [],
                   visualizations: [], privacy_level: nil, adapters: [],
                   validation_rules: [], recommendation_rules: [],
                   analysis_semantics: {}, matcher: nil)
      @id = Names.slug(id).freeze
      @version = version.to_s.freeze
      unless @version.match?(/\A\d+\.\d+\.\d+\z/)
        raise InvalidSchema, "template version must be semantic"
      end
      @domain = domain.to_s.freeze
      raise InvalidSchema, "unsupported template domain #{@domain.inspect}" unless DOMAINS.include?(@domain)

      @definition = definition.is_a?(Definition) ? definition : Definition.from_h(definition)
      unless @definition.slug == @id
        raise InvalidSchema, "template ID must match its Dataset slug"
      end
      raise InvalidSchema, "template parser must respond to parse" unless parser.respond_to?(:parse)

      @parser = parser
      @matcher = matcher
      @plugin = required(plugin, "plugin").freeze
      @keywords = strings(keywords)
      @header_aliases = aliases(header_aliases)
      @recommended_analyzers = strings(recommended_analyzers)
      @visualizations = strings(visualizations)
      @privacy_level = (privacy_level || @definition.sensitivity).to_s.freeze
      @adapters = strings(adapters)
      @validation_rules = strings(validation_rules)
      @recommendation_rules = strings(recommendation_rules)
      @analysis_semantics = deep_freeze(stringify(analysis_semantics))
      @digest = Digest::SHA256.hexdigest(JSON.generate(canonical(to_h))).freeze
      freeze
    end

    def display_name
      definition.name
    end

    def parse(observation)
      Array(@parser.parse(observation, self)).freeze
    end

    def normalize_header(value)
      key = value.to_s.downcase.strip.gsub(/[^a-z0-9]+/, "_").gsub(/\A_+|_+\z/, "")
      header_aliases.fetch(key, key)
    end

    def match(observation)
      candidates = []
      custom = @matcher && @matcher.call(observation, self)
      candidates << normalize_match(custom) if custom

      headers = TemplateParsers.headers(observation.content)
      unless headers.empty?
        normalized = headers.map { |header| normalize_header(header) }.uniq
        schema_names = definition.columns.map(&:name)
        matched = normalized & schema_names
        auto_fields = %w[observed_at occurred_at captured_at executed_at started_at test_date active]
        auto_fields += %w[marker] if id == "blood_tests" && normalized.include?("analyte")
        required = definition.columns.select(&:required?).map(&:name) - auto_fields
        missing_required = required - normalized
        distinctive = matched.reject do |name|
          %w[
            observed_at occurred_at occurred_on captured_at executed_at started_at ended_at test_date
            effective_from effective_until value unit notes comments
          ].include?(name)
        end
        if distinctive.any? && missing_required.empty?
          ratio = matched.length.to_f / [normalized.length, 1].max
          confidence = [0.62 + distinctive.length * 0.06 + ratio * 0.18, 0.98].min
          candidates << {
            "confidence" => confidence,
            "reason" => "matched #{matched.sort.join(', ')} source columns"
          }
        end
      end

      searchable = [observation.title, observation.source_filename, observation.content[0, 8_000]].compact.join(" ").downcase
      hits = keywords.select { |keyword| searchable.include?(keyword.downcase) }
      unless hits.empty?
        candidates << {
          "confidence" => [0.58 + hits.length * 0.08, 0.90].min,
          "reason" => "recognized #{hits.first(4).join(', ')} signals"
        }
      end
      candidates.max_by { |item| item.fetch("confidence") }
    end

    def to_h
      {
        "id" => id, "version" => version, "domain" => domain,
        "dataset" => definition.slug, "name" => definition.name,
        "schema" => definition.to_h, "indexes" => definition.columns.select(&:indexed?).map(&:name),
        "validation" => validation_rules, "units" => definition.columns.each_with_object({}) do |column, result|
          result[column.name] = column.unit if column.unit
        end,
        "recommended_analyzers" => recommended_analyzers,
        "default_visualizations" => visualizations,
        "privacy_level" => privacy_level, "future_adapters" => adapters,
        "recommendation_rules" => recommendation_rules,
        "analysis_semantics" => analysis_semantics, "plugin" => plugin
      }
    end

    private

    def normalize_match(value)
      data = stringify(value)
      confidence = Float(data.fetch("confidence"))
      unless confidence.between?(0.0, 1.0)
        raise InvalidSchema, "template matcher confidence must be between 0 and 1"
      end

      { "confidence" => confidence, "reason" => required(data.fetch("reason"), "match reason") }
    rescue KeyError, ArgumentError, TypeError
      raise InvalidSchema, "template matcher returned an invalid result"
    end

    def aliases(value)
      stringify(value).each_with_object({}) do |(key, item), result|
        normalized = key.downcase.gsub(/[^a-z0-9]+/, "_").gsub(/\A_+|_+\z/, "")
        result[normalized.freeze] = Names.identifier!(item, "template column alias").freeze
      end.freeze
    end

    def strings(value)
      Array(value).map { |item| required(item, "template contribution").freeze }.uniq.freeze
    end

    def required(value, label)
      text = value.to_s.strip
      raise InvalidSchema, "#{label} is required" if text.empty?

      text
    end

    def stringify(value)
      value.each_with_object({}) { |(key, item), result| result[key.to_s] = item }
    end

    def deep_freeze(value)
      case value
      when Hash
        value.each { |key, item| deep_freeze(key); deep_freeze(item) }
      when Array then value.each { |item| deep_freeze(item) }
      end
      value.freeze
    end

    def canonical(value)
      case value
      when Hash
        value.keys.map(&:to_s).sort.each_with_object({}) do |key, result|
          source_key = value.key?(key) ? key : value.keys.find { |item| item.to_s == key }
          result[key] = canonical(value[source_key])
        end
      when Array then value.map { |item| canonical(item) }
      else value
      end
    end
  end

  class TemplateSelection
    attr_reader :template, :confidence, :reason

    def initialize(template:, confidence:, reason:)
      @template = template
      @confidence = Float(confidence).round(6)
      @reason = reason.to_s.freeze
      freeze
    end

    def to_h
      {
        "template" => template.id, "template_version" => template.version,
        "template_digest" => template.digest, "domain" => template.domain,
        "dataset" => template.definition.slug, "display_name" => template.display_name,
        "confidence" => confidence, "reason" => reason, "plugin" => template.plugin
      }
    end
  end

  class TemplateRegistry
    MINIMUM_CONFIDENCE = 0.60

    def initialize
      @templates = {}
    end

    def register(template)
      raise InvalidSchema, "template registration requires a DatasetTemplate" unless template.is_a?(DatasetTemplate)

      key = [template.id, template.version]
      existing = @templates[key]
      if existing && existing.digest != template.digest
        raise DatasetConflict, "template #{template.id} #{template.version} conflicts with an existing registration"
      end
      return self if existing

      @templates[key] = template
      self
    end

    def register_plugin(plugin)
      unless plugin.respond_to?(:name) && plugin.respond_to?(:dataset_templates)
        raise InvalidSchema, "template plugin must expose name and dataset_templates"
      end
      Array(plugin.dataset_templates).each do |template|
        unless template.plugin == plugin.name.to_s
          raise InvalidSchema, "template plugin ownership does not match #{template.id}"
        end
        register(template)
      end
      self
    end

    def all
      @templates.values.sort_by { |template| [template.domain, template.id, template.version] }.freeze
    end

    def discover(domain: nil)
      selected = domain ? all.select { |template| template.domain == domain.to_s } : all
      selected.map(&:to_h).freeze
    end

    def fetch(id, version: nil)
      matches = all.select { |template| template.id == Names.slug(id) }
      matches = matches.select { |template| template.version == version.to_s } if version
      raise DatasetNotFound, "dataset template not found: #{id}" if matches.empty?

      matches.max_by { |template| template.version.split(".").map(&:to_i) }
    end

    def select(observation, domain: nil, minimum_confidence: MINIMUM_CONFIDENCE)
      candidates = all
      candidates = candidates.select { |template| template.domain == domain.to_s } if domain
      scored = candidates.each_with_object([]) do |template, result|
        match = template.match(observation)
        result << [template, match] if match
      end
      winner = scored.max_by { |template, match| [match.fetch("confidence"), template.id] }
      return nil unless winner && winner.last.fetch("confidence") >= minimum_confidence

      TemplateSelection.new(
        template: winner.first, confidence: winner.last.fetch("confidence"),
        reason: winner.last.fetch("reason")
      )
    end
  end

  module TemplateParsers
    module_function

    def headers(content)
      line = content.to_s.lines.find do |item|
        item.include?(",") || item.include?("\t") || item.count("|") >= 2
      end
      return [] unless line

      split(line).map { |item| item.to_s.strip }.reject(&:empty?)
    end

    def split(line)
      text = line.to_s.strip
      if text.include?("\t")
        text.split("\t", -1)
      elsif text.count("|") >= 2
        text.sub(/\A\s*\|/, "").sub(/\|\s*\z/, "").split("|", -1)
      else
        CSV.parse_line(text) || []
      end
    rescue CSV::MalformedCSVError
      []
    end

    class Delimited
      def parse(observation, template)
        lines = observation.content.lines
        header_index = lines.index do |line|
          raw = TemplateParsers.split(line)
          raw.length >= 2 && raw.any? { |item| item.to_s.match?(/[[:alpha:]]/) }
        end
        return [] unless header_index

        raw_headers = TemplateParsers.split(lines.fetch(header_index))
        headers = raw_headers.map { |header| template.normalize_header(header) }
        return [] if headers.empty? || headers.uniq.length != headers.length

        offset = lines[0...header_index + 1].join.length
        rows = []
        lines[(header_index + 1)..-1].to_a.each do |line|
          start_offset = offset
          offset += line.length
          next if line.strip.empty? || separator?(line)

          cells = TemplateParsers.split(line)
          next if cells.empty?
          cells += [nil] * (headers.length - cells.length) if cells.length < headers.length
          values = headers.each_with_index.each_with_object({}) do |(header, index), result|
            next unless template.definition.column?(header)
            value = clean(cells[index])
            result[header] = value unless value.nil?
          end
          values = defaults(values, observation, template)
          next if values.empty?

          coerced = template.definition.coerce_row(values)
          excerpt = line.chomp
          rows << ParsedTemplateRow.new(
            values: coerced, excerpt: excerpt,
            start_offset: start_offset, end_offset: start_offset + excerpt.length,
            page: observation.page_for(start_offset)
          )
        end
        rows
      end

      private

      def separator?(line)
        line.strip.match?(/\A\|?\s*:?-{2,}/)
      end

      def clean(value)
        text = value.to_s.strip
        return nil if text.empty? || text.match?(/\A(?:n\/a|na|null|-)\z/i)
        return true if text.match?(/\A(?:true|yes)\z/i)
        return false if text.match?(/\A(?:false|no)\z/i)
        return text.tr(",", ".").to_f if text.match?(/\A-?\d+[,.]\d+\z/)
        return text.to_i if text.match?(/\A-?\d+\z/)

        text
      end

      def defaults(values, observation, template)
        result = values.dup
        captured = observation.captured_at || Time.now
        date = captured.to_date.iso8601
        timestamp = captured.iso8601
        %w[observed_at occurred_at captured_at executed_at started_at].each do |name|
          result[name] ||= timestamp if template.definition.column?(name) && template.definition.column(name).required?
        end
        result["test_date"] ||= date if template.definition.column?("test_date")
        if template.id == "blood_tests"
          result["analyte"] ||= result["marker"]
          result["marker"] ||= result["analyte"]
          result["observed_at"] ||= "#{result.fetch('test_date', date)}T00:00:00Z"
          result["unit"] ||= "unspecified"
        end
        result["active"] = true if template.definition.column?("active") && !result.key?("active")
        result["currency"] = result["currency"].to_s.upcase if result["currency"]
        result
      end
    end

    class BloodTests
      DATE_PATTERN = /\b(?:test|collection|collected|report)?\s*date\s*[:\-]\s*(\d{4}-\d{2}-\d{2})\b/i.freeze
      META_PATTERN = /\A\s*(panel|specimen|laboratory|lab)\s*[:\-]\s*(.+?)\s*\z/i.freeze
      ROW_PATTERN = /\A\s*([[:alpha:]][[:alpha:]0-9 .()%+_\/-]{1,80}?)\s*[:|]?\s+(-?\d+(?:[.,]\d+)?)\s*([^\s|]+)?(?:\s+(-?\d+(?:[.,]\d+)?)\s*[-–]\s*(-?\d+(?:[.,]\d+)?))?(?:\s+(H|L|HIGH|LOW|ABNORMAL|\*))?\s*\z/i.freeze

      def parse(observation, template)
        table_rows = Delimited.new.parse(observation, template)
        return table_rows unless table_rows.empty?

        date = observation.content[DATE_PATTERN, 1] ||
               (observation.captured_at || Time.now).to_date.iso8601
        metadata = {}
        observation.content.lines.each do |line|
          match = META_PATTERN.match(line)
          next unless match

          key = match[1].downcase == "lab" ? "laboratory" : match[1].downcase
          metadata[key] = match[2].strip
        end
        rows = []
        offset = 0
        observation.content.lines.each do |line|
          start_offset = offset
          offset += line.length
          match = ROW_PATTERN.match(line)
          next unless match
          analyte = match[1].strip
          next if analyte.downcase.match?(/\A(?:test|collection|collected|report)?\s*date\z/) ||
                  %w[panel specimen laboratory lab].include?(analyte.downcase)

          reference_low = number(match[4])
          reference_high = number(match[5])
          values = {
            "test_date" => date, "panel" => metadata["panel"],
            "analyte" => analyte, "value" => number(match[2]),
            "unit" => match[3] || "unspecified",
            "reference_low" => reference_low, "reference_high" => reference_high,
            "reference_text" => reference_low && reference_high ? "#{match[4]}-#{match[5]}" : nil,
            "flag" => match[6] && match[6].upcase,
            "specimen" => metadata["specimen"], "laboratory" => metadata["laboratory"],
            "observed_at" => "#{date}T00:00:00Z", "marker" => analyte
          }.reject { |_key, value| value.nil? }
          coerced = template.definition.coerce_row(values)
          excerpt = line.chomp
          rows << ParsedTemplateRow.new(
            values: coerced, excerpt: excerpt,
            start_offset: start_offset, end_offset: start_offset + excerpt.length,
            page: observation.page_for(start_offset)
          )
        end
        rows
      end

      private

      def number(value)
        value && value.to_s.tr(",", ".").to_f
      end
    end
  end

  class BuiltInTemplatePlugin
    NAME = "core-dataset-templates"

    def name
      NAME
    end

    def dataset_templates
      @dataset_templates ||= specifications.map do |specification|
        build(specification)
      end.freeze
    end

    private

    def specifications
      [
        spec("blood_tests", "health", %w[laboratory lab blood-test bloodwork analyte biomarker],
             %w[health_trend reference_range], %w[line_chart reference_range_table],
             %w[pdf ocr csv excel hospital laboratory], blood_aliases,
             { "time_column" => "test_date", "label_column" => "analyte", "value_columns" => ["value"],
               "reference_low" => "reference_low", "reference_high" => "reference_high", "flag_column" => "flag" },
             parser: TemplateParsers::BloodTests.new, matcher: method(:blood_test_match)),
        spec("medication_schedules", "health", %w[medication medicine dosage schedule prescription],
             %w[medication_intervals], %w[schedule_timeline], %w[apple-health hospital pharmacy], medication_aliases),
        spec("blood_pressure", "health", %w[blood-pressure systolic diastolic],
             %w[health_trend], %w[line_chart range_band], %w[apple-health oura garmin fitbit hospital],
             aliases("date" => "observed_at", "timestamp" => "observed_at", "sys" => "systolic", "dia" => "diastolic")),
        spec("weight", "health", %w[weight body-weight mass], %w[health_trend], %w[line_chart],
             %w[apple-health oura garmin fitbit], aliases("date" => "observed_at", "weight" => "weight_kg", "kg" => "weight_kg")),
        spec("heart_rate", "health", %w[heart-rate pulse bpm], %w[health_trend], %w[line_chart],
             %w[apple-health oura garmin fitbit], aliases("date" => "observed_at", "heart_rate" => "bpm", "pulse" => "bpm")),
        spec("sleep", "health", %w[sleep bedtime wake duration], %w[health_trend], %w[sleep_timeline line_chart],
             %w[apple-health oura garmin fitbit], aliases("start" => "started_at", "end" => "ended_at", "duration" => "duration_hours")),
        spec("exercise", "health", %w[exercise workout activity distance calories], %w[health_trend], %w[activity_timeline],
             %w[apple-health oura garmin fitbit], aliases("start" => "started_at", "duration" => "duration_minutes", "distance" => "distance_km")),
        spec("nutrition", "health", %w[nutrition meal calories protein], %w[health_trend], %w[nutrition_summary],
             %w[apple-health csv], aliases("date" => "observed_at", "protein" => "protein_g")),
        spec("expenses", "finance", %w[expense expenses merchant spent category], %w[monthly_totals], %w[monthly_bar category_breakdown],
             %w[bank-export csv excel], aliases("date" => "occurred_on", "description" => "category", "payee" => "merchant")),
        spec("income", "finance", %w[income revenue payer salary], %w[monthly_totals], %w[monthly_bar],
             %w[bank-export csv excel], aliases("date" => "occurred_on", "description" => "category", "source" => "payer")),
        spec("subscriptions", "finance", %w[subscription recurring renewal billing], %w[recurring_cost], %w[subscription_table],
             %w[bank-export email csv], aliases("name" => "service", "cost" => "amount", "period" => "billing_period", "next_due" => "next_due_on")),
        spec("trades", "trading", %w[trade trades execution symbol ticker buy sell], %w[trade_performance], %w[trade_table],
             %w[interactive-brokers broker-export csv excel], aliases("date" => "executed_at", "timestamp" => "executed_at", "ticker" => "symbol", "qty" => "quantity", "commission" => "fees")),
        spec("positions", "trading", %w[position positions holdings portfolio symbol], %w[position_exposure], %w[position_table],
             %w[interactive-brokers broker-export csv], aliases("date" => "observed_at", "ticker" => "symbol", "qty" => "quantity", "avg_cost" => "average_cost")),
        spec("equity_curve", "trading", %w[equity nav drawdown portfolio-value], %w[equity_trend], %w[equity_curve drawdown_chart],
             %w[interactive-brokers broker-export csv], aliases("date" => "observed_at", "timestamp" => "observed_at", "nav" => "equity", "drawdown" => "drawdown_pct")),
        spec("contacts", "crm", %w[contact contacts customer client lead email phone], %w[contact_completeness], %w[contact_table],
             %w[google-contacts crm-export csv], aliases("date" => "captured_at", "company" => "organization", "job_title" => "role")),
        spec("meetings", "crm", %w[meeting meetings attendees participants outcome], %w[meeting_activity], %w[meeting_timeline],
             %w[calendar transcript email], aliases("date" => "occurred_at", "subject" => "title", "attendees" => "participants", "action_item" => "next_action")),
        spec("interactions", "crm", %w[interaction call email message contact follow-up], %w[interaction_cadence], %w[interaction_timeline],
             %w[email crm-export transcript], aliases("date" => "occurred_at", "type" => "kind", "person" => "contact", "action_item" => "next_action")),
        spec("key_value_measurements", "generic", %w[measurement metric key value unit], %w[generic_trend], %w[line_chart],
             %w[csv excel api], aliases("date" => "observed_at", "timestamp" => "observed_at", "name" => "key", "metric" => "key")),
        spec("custom_observation_log", "generic", %w[observation log category details], %w[observation_counts], %w[observation_table],
             %w[csv excel text], aliases("date" => "observed_at", "text" => "observation", "type" => "category"))
      ]
    end

    def spec(id, domain, keywords, analyzers, visualizations, adapters, header_aliases,
             semantics = nil, parser: nil, matcher: nil)
      {
        id: id, domain: domain, keywords: keywords, analyzers: analyzers,
        visualizations: visualizations, adapters: adapters, aliases: header_aliases,
        semantics: semantics || default_semantics(id), parser: parser, matcher: matcher
      }
    end

    def build(specification)
      definition = Builtins.fetch(specification.fetch(:id))
      DatasetTemplate.new(
        id: specification.fetch(:id), version: "1.0.0", domain: specification.fetch(:domain),
        definition: definition, parser: specification[:parser] || TemplateParsers::Delimited.new,
        plugin: NAME, keywords: specification.fetch(:keywords),
        header_aliases: specification.fetch(:aliases),
        recommended_analyzers: specification.fetch(:analyzers),
        visualizations: specification.fetch(:visualizations), privacy_level: definition.sensitivity,
        adapters: specification.fetch(:adapters), validation_rules: ["dataset_schema", "typed_rows"],
        recommendation_rules: specification.fetch(:domain) == "health" ? ["review_only"] : [],
        analysis_semantics: specification.fetch(:semantics), matcher: specification[:matcher]
      )
    end

    def blood_test_match(observation, _template)
      source = [observation.title, observation.source_filename, observation.content[0, 20_000]].compact.join(" ")
      lab = source.match?(/\b(?:laboratory|lab(?:oratory)?\s+report|blood\s+(?:test|panel|work)|reference\s+(?:range|interval)|specimen)\b/i)
      measurements = source.lines.count do |line|
        line.match?(/\b-?\d+(?:[.,]\d+)?\s+(?:mg\/dL|mmol\/L|g\/dL|ng\/mL|pg\/mL|mIU\/L|U\/L|%|[^\s]+)\b/i)
      end
      return { "confidence" => measurements >= 2 ? 0.98 : 0.92,
               "reason" => "recognized a clinical laboratory report" } if lab && measurements.positive?

      nil
    end

    def aliases(value)
      value
    end

    def blood_aliases
      aliases(
        "date" => "test_date", "collection_date" => "test_date", "result_date" => "test_date",
        "test" => "analyte", "marker" => "analyte", "biomarker" => "analyte",
        "result" => "value", "reference_range" => "reference_text", "range" => "reference_text",
        "low" => "reference_low", "high" => "reference_high", "status" => "flag",
        "lab" => "laboratory", "comment" => "comments"
      )
    end

    def medication_aliases
      aliases(
        "id" => "schedule_id", "name" => "medication", "schedule" => "schedule_json",
        "start_date" => "effective_from", "end_date" => "effective_until", "provider" => "prescribing_provider"
      )
    end

    def default_semantics(id)
      definition = Builtins.fetch(id)
      temporal = definition.columns.find { |column| %w[DATE DATETIME].include?(column.type) }
      numeric = definition.columns.select { |column| %w[INTEGER REAL].include?(column.type) }.map(&:name)
      { "time_column" => temporal && temporal.name, "value_columns" => numeric }.reject { |_key, value| value.nil? }
    end
  end

  class TemplateIntentClassifierPlugin
    class << self
      def register(classifier = KnowledgeSDK.intent_classifier, registry = StructuredDataset.template_registry)
        DatasetTemplate::DOMAINS.each do |domain|
          classifier.register(
            name: "dataset-template-#{domain}", domain: domain, route: "dataset"
          ) do |text, context|
            observation = TemplateObservation.new(
              source_type: context["source_type"] || "text", content: text,
              captured_at: context["captured_at"], source_uri: context["source_uri"],
              source_filename: context["source_filename"] || context["title"],
              title: context["title"], language: context["language"] || "und"
            )
            selection = registry.select(observation, domain: domain)
            next nil unless selection

            {
              "intent" => "dataset.template_import", "confidence" => selection.confidence,
              "explanation" => selection.reason,
              "slots" => selection.to_h
            }
          end
        end
      end
    end
  end

  class << self
    def template_registry
      @template_registry ||= TemplateRegistry.new.tap do |registry|
        registry.register_plugin(BuiltInTemplatePlugin.new)
      end
    end
  end
end

StructuredDataset::TemplateIntentClassifierPlugin.register
