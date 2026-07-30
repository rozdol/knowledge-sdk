# frozen_string_literal: true

require "date"

module KnowledgePlanning
  class ConstraintSet
    ALIASES = {
      "max_introductions" => "maximum_introductions",
      "max_meetings" => "maximum_meetings",
      "max_duration_days" => "maximum_duration_days"
    }.freeze
    SUPPORTED = %w[
      maximum_introductions maximum_meetings maximum_duration_days budget location
      start_date end_date date time language travel existing_contacts_only
      no_cold_outreach approval_required
    ].freeze

    attr_reader :values

    def initialize(values = {})
      raise InvalidConstraint, "constraints must be an object" unless values.is_a?(Hash)

      normalized = values.each_with_object({}) do |(key, value), result|
        name = ALIASES.fetch(key.to_s, key.to_s)
        raise InvalidConstraint, "unsupported constraint #{name.inspect}" unless SUPPORTED.include?(name)

        result[name] = normalize(name, value)
      end
      @values = Immutable.copy(normalized)
      freeze
    end

    def [](key)
      values[ALIASES.fetch(key.to_s, key.to_s)]
    end

    def key?(key)
      values.key?(ALIASES.fetch(key.to_s, key.to_s))
    end

    def merge(other)
      other = self.class.new(other) unless other.is_a?(self.class)
      self.class.new(values.merge(other.values))
    end

    def violations(plan:, simulation:, goal:, as_of:)
      result = []
      maximum(result, "maximum_introductions", simulation.introductions)
      maximum(result, "maximum_meetings", simulation.meetings)
      maximum(result, "maximum_duration_days", simulation.duration_days)
      maximum(result, "budget", simulation.budget)
      boolean_denial(result, "travel", simulation.travel_required, false)
      boolean_requirement(result, "no_cold_outreach", simulation.cold_outreach, false)
      if self["existing_contacts_only"] == true && plan.metadata["existing_contacts"] != true
        result << violation("existing_contacts_only", true, plan.metadata["existing_contacts"], "plan uses a non-existing contact")
      end
      if self["approval_required"] == true && plan.required_approvals.empty?
        result << violation("approval_required", true, false, "plan has no review gate")
      end
      if key?("location") && plan.metadata["location"].to_s.downcase != self["location"].to_s.downcase
        result << violation("location", self["location"], plan.metadata["location"], "plan location does not match")
      end
      if key?("language") && !Array(plan.metadata["languages"]).map(&:downcase).include?(self["language"].downcase)
        result << violation("language", self["language"], plan.metadata["languages"], "required language is unavailable")
      end
      planned_date = date_value(plan.metadata["scheduled_on"])
      exact_date = self["date"]
      if exact_date && planned_date != exact_date
        result << violation("date", exact_date.iso8601, planned_date && planned_date.iso8601, "plan date does not match")
      end
      start_date = self["start_date"]
      if start_date && (!planned_date || planned_date < start_date)
        result << violation("start_date", start_date.iso8601, planned_date && planned_date.iso8601, "plan starts too early or has no date")
      end
      end_date = self["end_date"] || goal.deadline
      completion = as_of + simulation.duration_days
      if end_date && completion > end_date
        result << violation("end_date", end_date.iso8601, completion.iso8601, "estimated completion exceeds the deadline")
      end
      if key?("time") && plan.metadata["time"].to_s != self["time"].to_s
        result << violation("time", self["time"], plan.metadata["time"], "plan time does not match")
      end
      result.sort_by { |item| item.fetch("constraint") }.freeze
    end

    def to_h
      values
    end

    private

    def normalize(name, value)
      case name
      when "maximum_introductions", "maximum_meetings", "maximum_duration_days"
        integer = Integer(value)
        raise InvalidConstraint, "#{name} must be non-negative" if integer.negative?
        integer
      when "budget"
        number = Float(value)
        raise InvalidConstraint, "budget must be non-negative" if number.negative?
        number.round(2)
      when "start_date", "end_date", "date"
        Date.iso8601(value.to_s)
      when "travel", "existing_contacts_only", "no_cold_outreach", "approval_required"
        unless value == true || value == false
          raise InvalidConstraint, "#{name} must be boolean"
        end
        value
      else
        string = value.to_s.strip
        raise InvalidConstraint, "#{name} cannot be empty" if string.empty?
        string
      end
    rescue ArgumentError, TypeError
      raise InvalidConstraint, "invalid value for #{name}"
    end

    def maximum(result, name, actual)
      return unless key?(name) && actual > self[name]

      result << violation(name, self[name], actual, "estimated value exceeds the maximum")
    end

    def boolean_denial(result, name, actual, allowed)
      return unless key?(name) && self[name] == allowed && actual != allowed

      result << violation(name, allowed, actual, "plan requires a forbidden capability")
    end

    def boolean_requirement(result, name, actual, expected)
      return unless self[name] == true && actual != expected

      result << violation(name, true, actual, "plan violates the required policy")
    end

    def violation(name, expected, actual, message)
      {
        "constraint" => name, "expected" => serial(expected),
        "actual" => serial(actual), "message" => message
      }.freeze
    end

    def serial(value)
      value.is_a?(Date) ? value.iso8601 : value
    end

    def date_value(value)
      return value if value.is_a?(Date)
      return nil if value.nil? || value.to_s.empty?

      Date.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end
  end
end
