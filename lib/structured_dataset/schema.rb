# frozen_string_literal: true

require "date"
require "json"
require "time"

module StructuredDataset
  module Names
    IDENTIFIER = /\A[a-z][a-z0-9_]{0,62}\z/.freeze
    module_function

    def slug(value)
      result = value.to_s.downcase.gsub(/[^a-z0-9]+/, "_").gsub(/\A_+|_+\z/, "")
      raise InvalidSchema, "dataset name must produce a safe lowercase slug" unless result.match?(IDENTIFIER)

      result.freeze
    end

    def identifier!(value, label = "identifier")
      result = value.to_s
      raise InvalidSchema, "invalid #{label} #{value.inspect}" unless result.match?(IDENTIFIER)

      result
    end
  end

  class Column
    TYPES = %w[TEXT INTEGER REAL BOOLEAN DATE DATETIME JSON].freeze
    KEYS = %w[name type required unique unit index min max enum pattern description].freeze

    attr_reader :name, :type, :unit, :minimum, :maximum, :enum, :pattern, :description

    def initialize(**attributes)
      data = attributes.each_with_object({}) { |(key, value), result| result[key.to_s] = value }
      unknown = data.keys - KEYS
      raise InvalidSchema, "unknown column properties: #{unknown.join(', ')}" unless unknown.empty?

      @name = Names.identifier!(data.fetch("name"), "column name").freeze
      @type = data.fetch("type").to_s.upcase.freeze
      raise InvalidSchema, "unsupported type #{@type.inspect} for #{@name}" unless TYPES.include?(@type)

      @required = !!data.fetch("required", false)
      @unique = !!data.fetch("unique", false)
      @indexed = !!data.fetch("index", false)
      @unit = optional_string(data["unit"], "unit")
      @description = optional_string(data["description"], "description")
      @minimum = optional_number(data["min"], "min")
      @maximum = optional_number(data["max"], "max")
      if !@minimum.nil? && !@maximum.nil? && @minimum > @maximum
        raise InvalidSchema, "#{@name}: min cannot exceed max"
      end
      @enum = Array(data["enum"]).map(&:to_s).uniq.freeze
      @pattern = compile_pattern(data["pattern"])
      validate_constraints!
      freeze
    rescue KeyError => error
      raise InvalidSchema, "column is missing #{error.key}"
    end

    def required?
      @required
    end

    def unique?
      @unique
    end

    def indexed?
      @indexed || @unique
    end

    def coerce(value)
      if value.nil? || (value.is_a?(String) && value.empty?)
        raise InvalidRow, "#{name} is required" if required?

        return nil
      end

      coerced = case type
                when "TEXT" then value.to_s
                when "INTEGER" then Integer(value)
                when "REAL" then Float(value)
                when "BOOLEAN" then boolean(value)
                when "DATE" then Date.iso8601(value.to_s).iso8601
                when "DATETIME" then datetime(value)
                when "JSON" then json(value)
                end
      validate_value!(coerced)
      coerced
    rescue ArgumentError, TypeError, JSON::ParserError
      raise InvalidRow, "#{name} must be #{type}"
    end

    def decode(value)
      return nil if value.nil?
      return value == 1 if type == "BOOLEAN"
      return JSON.parse(value) if type == "JSON"

      value
    rescue JSON::ParserError
      value
    end

    def to_h
      {
        name: name, type: type, required: required?, unique: unique?,
        unit: unit, index: indexed?, min: minimum, max: maximum,
        enum: enum.empty? ? nil : enum, pattern: pattern && pattern.source,
        description: description
      }.reject { |_key, value| value.nil? || value == false }
    end

    private

    def optional_string(value, field)
      return nil if value.nil?

      string = value.to_s.strip
      raise InvalidSchema, "#{name}: #{field} cannot be empty" if string.empty?

      string.freeze
    end

    def optional_number(value, field)
      return nil if value.nil?

      Float(value)
    rescue ArgumentError, TypeError
      raise InvalidSchema, "#{name}: #{field} must be numeric"
    end

    def compile_pattern(value)
      return nil if value.nil?

      Regexp.new("\\A(?:#{value})\\z").freeze
    rescue RegexpError => error
      raise InvalidSchema, "#{name}: invalid pattern: #{error.message}"
    end

    def validate_constraints!
      if (!minimum.nil? || !maximum.nil?) && !%w[INTEGER REAL].include?(type)
        raise InvalidSchema, "#{name}: min/max require INTEGER or REAL"
      end
      raise InvalidSchema, "#{name}: enum values must be unique strings" if enum.any?(&:empty?)
      raise InvalidSchema, "#{name}: pattern requires TEXT" if pattern && type != "TEXT"
    end

    def boolean(value)
      return 1 if value == true || value == 1 || value.to_s.match?(/\A(?:true|yes|1)\z/i)
      return 0 if value == false || value == 0 || value.to_s.match?(/\A(?:false|no|0)\z/i)

      raise ArgumentError, "invalid boolean"
    end

    def datetime(value)
      time = value.is_a?(Time) ? value : Time.iso8601(value.to_s)
      time.iso8601(6)
    end

    def json(value)
      parsed = value.is_a?(String) ? JSON.parse(value) : value
      JSON.generate(parsed)
    end

    def validate_value!(value)
      numeric = type == "INTEGER" || type == "REAL"
      raise InvalidRow, "#{name} must be at least #{minimum}" if numeric && !minimum.nil? && value < minimum
      raise InvalidRow, "#{name} must be at most #{maximum}" if numeric && !maximum.nil? && value > maximum
      comparable = type == "JSON" ? JSON.parse(value) : value
      raise InvalidRow, "#{name} must be one of #{enum.join(', ')}" if !enum.empty? && !enum.include?(comparable.to_s)
      raise InvalidRow, "#{name} has an invalid format" if pattern && !pattern.match?(value.to_s)
    end
  end

  class Definition
    RESERVED_COLUMNS = %w[
      row_id created_at updated_at created_by source observation_id proposal_id approval_id intent_id
    ].freeze
    KEYS = %w[slug name kind purpose sensitivity columns].freeze

    attr_reader :slug, :name, :kind, :purpose, :sensitivity, :columns

    def initialize(**attributes)
      data = attributes.each_with_object({}) { |(key, value), result| result[key.to_s] = value }
      unknown = data.keys - KEYS
      raise InvalidSchema, "unknown dataset properties: #{unknown.join(', ')}" unless unknown.empty?

      @slug = Names.slug(data.fetch("slug"))
      @name = required(data.fetch("name"), "name").freeze
      @kind = Names.identifier!(data.fetch("kind", @slug), "dataset kind").freeze
      @purpose = required(data.fetch("purpose"), "purpose").freeze
      @sensitivity = data.fetch("sensitivity", "private").to_s.freeze
      unless %w[normal private restricted].include?(@sensitivity)
        raise InvalidSchema, "invalid dataset sensitivity #{@sensitivity.inspect}"
      end
      @columns = Array(data.fetch("columns")).map do |column|
        raise InvalidSchema, "each column must be an object" unless column.is_a?(Hash)

        Column.new(**column.each_with_object({}) { |(key, item), result| result[key.to_sym] = item })
      end.freeze
      raise InvalidSchema, "dataset requires at least one column" if @columns.empty?
      duplicates = @columns.group_by(&:name).select { |_key, values| values.length > 1 }.keys
      raise InvalidSchema, "duplicate columns: #{duplicates.join(', ')}" unless duplicates.empty?
      conflicts = @columns.map(&:name) & RESERVED_COLUMNS
      raise InvalidSchema, "reserved columns: #{conflicts.join(', ')}" unless conflicts.empty?
      freeze
    rescue KeyError => error
      raise InvalidSchema, "dataset is missing #{error.key}"
    end

    def column(name)
      columns.find { |column| column.name == name.to_s } || raise(InvalidRow, "unknown column #{name.inspect}")
    end

    def column?(name)
      columns.any? { |column| column.name == name.to_s }
    end

    def coerce_row(values, partial: false)
      data = values.each_with_object({}) { |(key, value), result| result[key.to_s] = value }
      unknown = data.keys - columns.map(&:name)
      raise InvalidRow, "unknown columns: #{unknown.join(', ')}" unless unknown.empty?

      columns.each_with_object({}) do |column, result|
        next if partial && !data.key?(column.name)

        result[column.name] = column.coerce(data[column.name])
      end
    end

    def decode_row(row)
      row.each_with_object({}) do |(key, value), result|
        next if key.is_a?(Integer)

        column = columns.find { |item| item.name == key.to_s }
        result[key.to_s] = column ? column.decode(value) : value
      end
    end

    def to_h
      {
        slug: slug, name: name, kind: kind, purpose: purpose,
        sensitivity: sensitivity, columns: columns.map(&:to_h)
      }
    end

    def self.from_h(value)
      raise InvalidSchema, "dataset schema must be an object" unless value.is_a?(Hash)

      new(**value.each_with_object({}) { |(key, item), result| result[key.to_sym] = item })
    end

    private

    def required(value, field)
      string = value.to_s.strip
      raise InvalidSchema, "dataset #{field} is required" if string.empty?

      string
    end
  end

  module Builtins
    module_function

    def fetch(slug)
      data = definitions[Names.slug(slug)]
      data && Definition.from_h(JSON.parse(JSON.generate(data)))
    end

    def keys
      definitions.keys.sort.freeze
    end

    def definitions
      @definitions ||= begin
        observed = ->(extra) { [{ name: "observed_at", type: "DATETIME", required: true, index: true }] + extra }
        {
          "medication_schedules" => spec(
            "Medication Schedules", "medication_schedules", "Track active medication schedules", [
              { name: "effective_on", type: "DATE", required: true, index: true },
              { name: "medication", type: "TEXT", required: true, unique: true },
              { name: "dose", type: "REAL" }, { name: "unit", type: "TEXT" },
              { name: "schedule", type: "TEXT", required: true },
              { name: "active", type: "BOOLEAN", required: true }
            ]
          ),
          "medication_log" => spec("Medication Log", "medication_log", "Track medication adherence", observed.call([
            { name: "medication", type: "TEXT", required: true, index: true },
            { name: "dose", type: "REAL" }, { name: "unit", type: "TEXT" },
            { name: "action", type: "TEXT", required: true, enum: %w[taken missed skipped] },
            { name: "notes", type: "TEXT" }
          ])),
          "blood_tests" => spec("Blood Tests", "blood_tests", "Longitudinal laboratory results", observed.call([
            { name: "marker", type: "TEXT", required: true, index: true },
            { name: "value", type: "REAL", required: true }, { name: "unit", type: "TEXT", required: true },
            { name: "reference_low", type: "REAL" }, { name: "reference_high", type: "REAL" },
            { name: "laboratory", type: "TEXT" }, { name: "notes", type: "TEXT" }
          ])),
          "body_measurements" => spec("Body Measurements", "body_measurements", "Track physical measurements", observed.call([
            { name: "measurement", type: "TEXT", required: true, index: true },
            { name: "value", type: "REAL", required: true }, { name: "unit", type: "TEXT", required: true }
          ])),
          "blood_pressure" => spec("Blood Pressure", "blood_pressure", "Track blood pressure readings", observed.call([
            { name: "systolic", type: "INTEGER", required: true, min: 40, max: 300 },
            { name: "diastolic", type: "INTEGER", required: true, min: 30, max: 200 },
            { name: "pulse", type: "INTEGER", min: 20, max: 250 }, { name: "notes", type: "TEXT" }
          ])),
          "heart_rate" => spec("Heart Rate", "heart_rate", "Track heart rate", observed.call([
            { name: "bpm", type: "INTEGER", required: true, min: 20, max: 300 }, { name: "context", type: "TEXT" }
          ])),
          "weight" => spec("Weight", "weight", "Track body weight", observed.call([
            { name: "weight_kg", type: "REAL", required: true, min: 1, max: 1000 }, { name: "notes", type: "TEXT" }
          ])),
          "sleep" => spec("Sleep", "sleep", "Track sleep duration and quality", [
            { name: "started_at", type: "DATETIME", required: true, index: true },
            { name: "ended_at", type: "DATETIME" }, { name: "duration_hours", type: "REAL", required: true, min: 0, max: 48 },
            { name: "quality", type: "INTEGER", min: 1, max: 5 }, { name: "notes", type: "TEXT" }
          ]),
          "exercise" => spec("Exercise", "exercise", "Track exercise sessions", [
            { name: "started_at", type: "DATETIME", required: true, index: true },
            { name: "activity", type: "TEXT", required: true, index: true },
            { name: "duration_minutes", type: "REAL", required: true, min: 0 },
            { name: "distance_km", type: "REAL", min: 0 }, { name: "calories", type: "REAL", min: 0 }
          ]),
          "nutrition" => spec("Nutrition", "nutrition", "Track meals and nutrition", observed.call([
            { name: "meal", type: "TEXT", required: true }, { name: "calories", type: "REAL", min: 0 },
            { name: "protein_g", type: "REAL", min: 0 }, { name: "details", type: "JSON" }
          ])),
          "expenses" => money_spec("Expenses", "expenses", "Track expenses", "merchant"),
          "income" => money_spec("Income", "income", "Track income", "payer"),
          "subscriptions" => spec("Subscriptions", "subscriptions", "Track recurring subscriptions", [
            { name: "service", type: "TEXT", required: true, unique: true },
            { name: "amount", type: "REAL", required: true, min: 0 },
            { name: "currency", type: "TEXT", required: true, pattern: "[A-Z]{3}" },
            { name: "billing_period", type: "TEXT", required: true }, { name: "next_due_on", type: "DATE", index: true },
            { name: "active", type: "BOOLEAN", required: true }
          ]),
          "vehicle_maintenance" => spec("Vehicle Maintenance", "vehicle_maintenance", "Track vehicle service history", [
            { name: "occurred_on", type: "DATE", required: true, index: true },
            { name: "vehicle", type: "TEXT", required: true }, { name: "service", type: "TEXT", required: true },
            { name: "odometer_km", type: "INTEGER", min: 0 }, { name: "cost", type: "REAL", min: 0 },
            { name: "currency", type: "TEXT", pattern: "[A-Z]{3}" }, { name: "notes", type: "TEXT" }
          ])
        }.freeze
      end
    end

    def spec(name, kind, purpose, columns)
      { slug: kind, name: name, kind: kind, purpose: purpose, sensitivity: "private", columns: columns }
    end

    def money_spec(name, kind, purpose, counterparty)
      spec(name, kind, purpose, [
        { name: "occurred_on", type: "DATE", required: true, index: true },
        { name: "category", type: "TEXT", required: true, index: true },
        { name: "amount", type: "REAL", required: true, min: 0 },
        { name: "currency", type: "TEXT", required: true, pattern: "[A-Z]{3}" },
        { name: counterparty, type: "TEXT" }, { name: "notes", type: "TEXT" }
      ])
    end
  end
end
