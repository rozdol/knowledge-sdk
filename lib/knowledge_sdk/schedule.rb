# frozen_string_literal: true

require "date"
require "json"

module KnowledgeSDK
  # Generic, immutable recurrence value used by Dataset-backed plugins. It is
  # deliberately independent of medications and contains no persistence or
  # execution behavior.
  class Schedule
    VERSION = 1
    FREQUENCIES = %w[
      daily weekly monthly every_n_days cron prn custom_interval
    ].freeze
    DAYS = %w[monday tuesday wednesday thursday friday saturday sunday].freeze
    TIME_OF_DAY = %w[morning day evening night].freeze
    MEAL_RELATIONS = %w[before_food with_food after_food independent].freeze
    INTERVAL_UNITS = %w[minute minutes hour hours day days week weeks month months].freeze
    KEYS = %w[
      version frequency times days_of_week days_of_month interval cron
      occurrences_per_period constraints extensions
    ].freeze
    TIME_KEYS = %w[time_of_day local_time meal_relation fasting extensions].freeze

    attr_reader :frequency

    def initialize(value)
      data = stringify_hash(value, "schedule")
      unknown = data.keys - KEYS
      raise ArgumentError, "unknown schedule properties: #{unknown.join(', ')}" unless unknown.empty?

      version = Integer(data.fetch("version", VERSION))
      raise ArgumentError, "unsupported schedule version #{version}" unless version == VERSION

      @frequency = data.fetch("frequency").to_s.freeze
      unless FREQUENCIES.include?(@frequency)
        raise ArgumentError, "unsupported schedule frequency #{@frequency.inspect}"
      end

      @times = Array(data["times"]).map { |item| normalize_time(item) }.freeze
      @days_of_week = Array(data["days_of_week"]).map do |item|
        item.to_s.downcase.freeze
      end.uniq.freeze
      invalid_days = @days_of_week - DAYS
      raise ArgumentError, "invalid days_of_week: #{invalid_days.join(', ')}" unless invalid_days.empty?

      @days_of_month = Array(data["days_of_month"]).map { |item| Integer(item) }.uniq.sort.freeze
      unless @days_of_month.all? { |day| day.between?(1, 31) }
        raise ArgumentError, "days_of_month must contain integers from 1 through 31"
      end

      @interval = normalize_interval(data["interval"])
      @cron = optional_string(data["cron"])
      @occurrences_per_period = optional_positive_integer(data["occurrences_per_period"])
      @constraints = normalize_object(data.fetch("constraints", {}), "constraints")
      @extensions = normalize_object(data.fetch("extensions", {}), "extensions")
      validate_recurrence!
      freeze
    rescue KeyError => error
      raise ArgumentError, "schedule is missing #{error.key}"
    rescue TypeError
      raise ArgumentError, "schedule must be an object"
    end

    def self.from_h(value)
      return value if value.is_a?(self)

      parsed = value.is_a?(String) ? JSON.parse(value) : value
      new(parsed)
    rescue JSON::ParserError => error
      raise ArgumentError, "schedule JSON is invalid: #{error.message}"
    end

    def self.from_legacy(value, details: nil, fasting: false)
      entries = Array(details)
      entries = [{ "schedule" => value, "fasting" => fasting }] if entries.empty?
      schedules = entries.map do |entry|
        item = entry.is_a?(Hash) ? entry : { "schedule" => entry }
        legacy_time(item["schedule"] || item[:schedule], item)
      end
      frequencies = schedules.map { |item| item.delete("_frequency") }.uniq
      occurrences = schedules.map { |item| item.delete("_occurrences") }.compact.max
      untimed = schedules.select do |item|
        !item.key?("time_of_day") && !item.key?("local_time")
      end
      times = schedules.reject do |item|
        item.empty? || (!item.key?("time_of_day") && !item.key?("local_time"))
      end.uniq
      payload = {
        "version" => VERSION,
        "frequency" => frequencies.length == 1 ? frequencies.first : "daily",
        "times" => times
      }
      payload["occurrences_per_period"] = occurrences if occurrences
      unless untimed.empty?
        payload["constraints"] = untimed.each_with_object({}) do |item, result|
          item.each { |key, entry| result[key] = entry }
        end
      end
      new(payload)
    end

    def self.active_during?(effective_from, effective_until, from: nil, to: nil)
      starts = Date.iso8601(effective_from.to_s)
      ends = effective_until && !effective_until.to_s.empty? ? Date.iso8601(effective_until.to_s) : nil
      lower = from && date_value(from)
      upper = to && date_value(to)
      return false if upper && starts > upper
      return false if lower && ends && ends < lower

      true
    rescue ArgumentError
      false
    end

    def to_h
      {
        "version" => VERSION, "frequency" => frequency,
        "times" => @times.empty? ? nil : @times,
        "days_of_week" => @days_of_week.empty? ? nil : @days_of_week,
        "days_of_month" => @days_of_month.empty? ? nil : @days_of_month,
        "interval" => @interval, "cron" => @cron,
        "occurrences_per_period" => @occurrences_per_period,
        "constraints" => @constraints.empty? ? nil : @constraints,
        "extensions" => @extensions.empty? ? nil : @extensions
      }.reject { |_key, item| item.nil? }
    end

    def to_json(*arguments)
      JSON.generate(to_h, *arguments)
    end

    private

    def normalize_time(value)
      data = stringify_hash(value, "schedule time")
      unknown = data.keys - TIME_KEYS
      raise ArgumentError, "unknown schedule time properties: #{unknown.join(', ')}" unless unknown.empty?

      time_of_day = optional_string(data["time_of_day"])
      local_time = optional_string(data["local_time"])
      if time_of_day && !TIME_OF_DAY.include?(time_of_day)
        raise ArgumentError, "invalid time_of_day #{time_of_day.inspect}"
      end
      if local_time && !local_time.match?(/\A(?:[01]\d|2[0-3]):[0-5]\d\z/)
        raise ArgumentError, "local_time must use HH:MM"
      end
      raise ArgumentError, "schedule time requires time_of_day or local_time" unless time_of_day || local_time

      meal = optional_string(data["meal_relation"])
      if meal && !MEAL_RELATIONS.include?(meal)
        raise ArgumentError, "invalid meal_relation #{meal.inspect}"
      end
      fasting = data["fasting"]
      unless fasting.nil? || fasting == true || fasting == false
        raise ArgumentError, "fasting must be boolean"
      end
      {
        "time_of_day" => time_of_day, "local_time" => local_time,
        "meal_relation" => meal, "fasting" => fasting,
        "extensions" => normalize_object(data.fetch("extensions", {}), "time extensions")
      }.reject { |_key, item| item.nil? || (item.respond_to?(:empty?) && item.empty?) }.freeze
    end

    def normalize_interval(value)
      return nil if value.nil?

      data = stringify_hash(value, "schedule interval")
      every = Integer(data.fetch("every"))
      unit = data.fetch("unit").to_s.downcase.freeze
      raise ArgumentError, "schedule interval every must be positive" unless every.positive?
      raise ArgumentError, "invalid schedule interval unit #{unit.inspect}" unless INTERVAL_UNITS.include?(unit)

      normalized = { "every" => every, "unit" => unit }
      if data["anchor_date"]
        normalized["anchor_date"] = Date.iso8601(data["anchor_date"].to_s).iso8601.freeze
      end
      extras = data.keys - %w[every unit anchor_date]
      raise ArgumentError, "unknown interval properties: #{extras.join(', ')}" unless extras.empty?

      normalized.freeze
    rescue KeyError => error
      raise ArgumentError, "schedule interval is missing #{error.key}"
    end

    def validate_recurrence!
      raise ArgumentError, "weekly schedules require days_of_week" if frequency == "weekly" && @days_of_week.empty?
      raise ArgumentError, "monthly schedules require days_of_month" if frequency == "monthly" && @days_of_month.empty?
      if %w[every_n_days custom_interval].include?(frequency) && @interval.nil?
        raise ArgumentError, "#{frequency} schedules require interval"
      end
      if frequency == "every_n_days" && !%w[day days].include?(@interval.fetch("unit"))
        raise ArgumentError, "every_n_days schedules require a day interval"
      end
      if frequency == "cron"
        raise ArgumentError, "cron schedules require cron" unless @cron
        raise ArgumentError, "cron must contain five fields" unless @cron.split(/\s+/).length == 5
      elsif @cron
        raise ArgumentError, "cron is only valid for cron schedules"
      end
    end

    def stringify_hash(value, label)
      raise TypeError unless value.is_a?(Hash)

      value.each_with_object({}) { |(key, item), result| result[key.to_s] = item }
    rescue TypeError
      raise ArgumentError, "#{label} must be an object"
    end

    def normalize_object(value, label)
      data = stringify_hash(value, label)
      deep_copy(data).freeze
    end

    def deep_copy(value)
      case value
      when Hash
        value.each_with_object({}) { |(key, item), result| result[key.to_s.freeze] = deep_copy(item) }.freeze
      when Array
        value.map { |item| deep_copy(item) }.freeze
      when String
        value.dup.freeze
      else
        value.frozen? ? value : value.dup.freeze
      end
    rescue TypeError
      value.freeze
    end

    def optional_string(value)
      return nil if value.nil?

      text = value.to_s.strip
      text.empty? ? nil : text.freeze
    end

    def optional_positive_integer(value)
      return nil if value.nil?

      number = Integer(value)
      raise ArgumentError unless number.positive?

      number
    rescue ArgumentError, TypeError
      raise ArgumentError, "occurrences_per_period must be a positive integer"
    end

    class << self
      private

      def legacy_time(value, attributes)
        text = value.to_s.downcase.strip
        item = {}
        item["_frequency"] = "daily"
        item["time_of_day"] = "morning" if text.match?(/morning|утр|πρωί/)
        item["time_of_day"] = "day" if text.match?(/afternoon|дн[её]м|απόγευμα/)
        item["time_of_day"] = "evening" if text.match?(/evening|вечер|βράδυ/)
        item["time_of_day"] = "night" if text.match?(/night|ноч/)
        if (match = text.match(/(?:at\s+)?(\d{1,2})(?::(\d{2}))?\s*([ap]m)?/))
          hour = match[1].to_i
          hour = 0 if match[3] == "am" && hour == 12
          hour += 12 if match[3] == "pm" && hour < 12
          item["local_time"] = format("%02d:%02d", hour, (match[2] || "00").to_i)
        end
        item["_occurrences"] = 2 if text.match?(/twice|два\s+раза|δύο\s+φορές/)
        item["_occurrences"] = 1 if text.match?(/once|раз\s+в\s+день|μία\s+φορά/)
        fasting = attributes["fasting"] || attributes[:fasting]
        item["fasting"] = true if fasting
        relation = attributes["meal_relation"] || attributes[:meal_relation]
        item["meal_relation"] = relation.to_s if MEAL_RELATIONS.include?(relation.to_s)
        item["meal_relation"] = "before_food" if fasting || text.match?(/before|до\s+еды|πριν/)
        item["meal_relation"] = "after_food" if text.match?(/after|после\s+еды|μετά/)
        item
      end

      def date_value(value)
        return value if value.is_a?(Date) && !value.is_a?(DateTime)
        return value.to_date if value.respond_to?(:to_date)

        Date.iso8601(value.to_s[0, 10])
      end
    end
  end
end
