# frozen_string_literal: true

require "date"
require "digest"
require "json"

module StructuredDataset
  # Trusted, versioned migration for the Phase 13 medication schedule shape.
  # The copy-and-verify operation is executed only by an approved
  # UpgradeDatasetSchema Intent whose migration_id matches this class.
  class MedicationScheduleSchemaMigration
    ID = "medication_schedules_v2".freeze

    class << self
      def legacy?(definition)
        names = definition.columns.map(&:name)
        names.include?("schedule") && names.include?("effective_on") &&
          !names.include?("schedule_json") && !names.include?("effective_from")
      end

      def target(current = nil)
        definition = Builtins.fetch("medication_schedules")
        return definition unless current

        Definition.from_h(
          definition.to_h.merge(
            name: current.name, kind: current.kind, purpose: current.purpose,
            sensitivity: current.sensitivity
          )
        )
      end

      def transform(row)
        details = parse_details(row["schedule_details"])
        schedule = KnowledgeSDK::Schedule.from_legacy(
          row["schedule"], details: details
        )
        route = details.map do |entry|
          entry["administration_route"] || entry["route"]
        end.compact.uniq
        values = {
          "schedule_id" => schedule_id(row.fetch("row_id")),
          "medication" => row.fetch("medication"),
          "dose" => row["dose"], "unit" => row["unit"],
          "route" => route.length == 1 ? route.first : nil,
          "schedule_json" => schedule.to_json,
          "effective_from" => row.fetch("effective_on"),
          "effective_until" => nil,
          "active" => row.key?("active") ? row["active"] : 1,
          "reason" => nil, "prescribing_provider" => nil, "notes" => nil
        }
        Definition::RESERVED_COLUMNS.each { |column| values[column] = row[column] }
        values
      end

      private

      def parse_details(value)
        parsed = value.is_a?(String) ? JSON.parse(value) : value
        Array(parsed).select { |item| item.is_a?(Hash) }.map do |item|
          item.each_with_object({}) { |(key, entry), result| result[key.to_s] = entry }
        end
      rescue JSON::ParserError
        []
      end

      def schedule_id(row_id)
        suffix = row_id.to_s[/_([0-9A-HJKMNP-TV-Z]{26})\z/, 1]
        return "medschedule_#{suffix}" if suffix

        digest = Digest::SHA256.hexdigest(row_id.to_s).upcase[0, 26]
        "medschedule_#{digest}"
      end
    end
  end

  module MedicationScheduleOperations
    DATASET = "medication_schedules".freeze
    VALUE_COLUMNS = %w[
      schedule_id medication dose unit route schedule_json effective_from
      effective_until active reason prescribing_provider notes
    ].freeze
    module_function

    def validate_row!(row, partial: false)
      if row.key?("schedule_id") && row["schedule_id"] &&
         !row["schedule_id"].to_s.match?(/\Amedschedule_[0-9A-HJKMNP-TV-Z]{26}\z/)
        raise InvalidRow, "schedule_id must be an immutable medschedule_<ULID>"
      end
      if row.key?("schedule_json") && row["schedule_json"]
        row["schedule_json"] = schedule_hash(row["schedule_json"]).to_json
      end
      return row if partial && !(row.key?("effective_from") && row.key?("effective_until"))

      if row["effective_from"] && row["effective_until"] &&
         Date.iso8601(row["effective_until"].to_s) < Date.iso8601(row["effective_from"].to_s)
        raise InvalidRow, "effective_until cannot precede effective_from"
      end
      row
    rescue ArgumentError
      raise InvalidRow, "effective interval must use ISO 8601 dates"
    end

    def create(engine, intent, provenance)
      engine.insert(DATASET, values_for(intent), provenance)
    end

    def replace(engine, intent, provenance)
      values = values_for(intent)
      target_id = intent.schedule_id
      legacy_replace = intent.schedule_json.nil? && !intent.schedule.nil?
      if intent.replace_all || legacy_replace
        requested_close = Date.iso8601(values.fetch(:effective_from).to_s) - 1
        current_starts = engine.query(DATASET, limit: 10_000).select do |row|
          row["medication"].to_s == intent.medication.to_s &&
            (row["active"] == true || row["active"] == 1) &&
            (row["effective_until"].nil? || row["effective_until"].to_s.empty?)
        end.map { |row| Date.iso8601(row.fetch("effective_from")) }
        close_on = ([requested_close] + current_starts).max.iso8601
        return engine.evolve(
          DATASET,
          match: { medication: intent.medication, active: true, effective_until: nil },
          close_values: { effective_until: close_on },
          values: values, provenance: provenance, require_match: false
        )
      end
      return engine.insert(DATASET, values, provenance) if target_id.to_s.empty?

      engine.evolve(
        DATASET, match: { schedule_id: target_id },
        close_values: { effective_until: previous_day(values.fetch(:effective_from)) },
        values: values, provenance: provenance
      )
    end

    def pause(engine, intent, provenance)
      prior = target(
        engine, intent.schedule_id, intent.medication, at: intent.paused_on, active: true
      )
      values = copy(prior).merge(
        schedule_id: intent.replacement_schedule_id,
        effective_from: intent.paused_on, effective_until: nil,
        active: false, reason: intent.reason || "paused"
      )
      engine.evolve(
        DATASET, match: { schedule_id: prior.fetch("schedule_id") },
        close_values: { effective_until: closing_date(prior, intent.paused_on) },
        values: values, provenance: provenance
      )
    end

    def resume(engine, intent, provenance)
      prior = target(
        engine, intent.schedule_id, intent.medication, at: intent.resumed_on, active: false
      )
      values = copy(prior).merge(
        schedule_id: intent.replacement_schedule_id,
        effective_from: intent.resumed_on, effective_until: intent.effective_until,
        active: true, reason: intent.reason || "resumed"
      )
      engine.evolve(
        DATASET, match: { schedule_id: prior.fetch("schedule_id") },
        close_values: { effective_until: closing_date(prior, intent.resumed_on) },
        values: values, provenance: provenance
      )
    end

    def stop(engine, intent, provenance)
      rows = engine.query(DATASET, limit: 10_000).select do |row|
        row["medication"].to_s.casecmp?(intent.medication.to_s) &&
          (row["active"] == true || row["active"] == 1) &&
          KnowledgeSDK::Schedule.active_during?(
            row["effective_from"], row["effective_until"],
            from: intent.stopped_on, to: intent.stopped_on
          )
      end
      raise RowNotFound, "medication schedule version was not found" if rows.empty?

      closing_dates = rows.map { |row| closing_date(row, intent.stopped_on) }.uniq
      if closing_dates.length != 1
        raise InvalidRow, "active schedule versions require different stop boundaries"
      end
      engine.update_matching_ids(
        DATASET, identifier: :schedule_id,
        ids: rows.map { |row| row.fetch("schedule_id") },
        values: {
          effective_until: closing_dates.first,
          reason: intent.reason || "discontinued"
        },
        provenance: provenance
      )
    end

    def modify_dose(engine, intent, provenance)
      prior = target(
        engine, intent.schedule_id, intent.medication, at: intent.effective_from, active: true
      )
      values = copy(prior).merge(
        schedule_id: intent.replacement_schedule_id,
        dose: intent.dose, unit: intent.unit || prior["unit"],
        effective_from: intent.effective_from, effective_until: nil,
        active: true, reason: intent.reason || "dose_modified"
      )
      evolve_one(engine, prior, values, intent.effective_from, provenance)
    end

    def modify_schedule(engine, intent, provenance)
      prior = target(
        engine, intent.schedule_id, intent.medication, at: intent.effective_from, active: true
      )
      values = copy(prior).merge(
        schedule_id: intent.replacement_schedule_id,
        schedule_json: schedule_hash(intent.schedule_json),
        effective_from: intent.effective_from, effective_until: nil,
        active: true, reason: intent.reason || "schedule_modified"
      )
      evolve_one(engine, prior, values, intent.effective_from, provenance)
    end

    def row_values(intent)
      if intent.is_a?(KnowledgeGraph::CreateMedicationSchedule) ||
         intent.is_a?(KnowledgeGraph::ReplaceMedicationSchedule)
        values_for(intent)
      else
        {}
      end
    end

    def values_for(intent)
      legacy = intent.respond_to?(:schedule) && intent.schedule
      schedule = intent.respond_to?(:schedule_json) && intent.schedule_json
      if schedule.nil? && legacy.nil?
        raise InvalidRow, "medication schedule requires schedule_json"
      end
      schedule ||= KnowledgeSDK::Schedule.from_legacy(
        legacy, details: intent.respond_to?(:schedule_details) ? intent.schedule_details : nil
      ).to_h
      starts = if intent.respond_to?(:effective_from) && intent.effective_from
                 intent.effective_from
               elsif intent.respond_to?(:effective_on)
                 intent.effective_on
               end
      identifier = if intent.respond_to?(:replacement_schedule_id) && intent.replacement_schedule_id
                     intent.replacement_schedule_id
                   elsif intent.respond_to?(:schedule_id) && intent.schedule_id
                     intent.schedule_id
                   end
      identifier ||= KnowledgeGraph::IdGenerator.new.generate("medschedule")
      details = if legacy && intent.respond_to?(:schedule_details)
                  Array(intent.schedule_details).select { |item| item.is_a?(Hash) }
                else
                  []
                end
      legacy_routes = details.map do |item|
        item["administration_route"] || item[:administration_route] ||
          item["route"] || item[:route]
      end.compact.uniq
      route = intent.respond_to?(:route) ? intent.route : nil
      route ||= legacy_routes.first if legacy_routes.length == 1
      values = {
        schedule_id: identifier, medication: intent.medication,
        dose: intent.respond_to?(:dose) ? intent.dose : nil,
        unit: intent.respond_to?(:unit) ? intent.unit : nil,
        route: route,
        schedule_json: schedule_hash(schedule), effective_from: starts,
        effective_until: intent.respond_to?(:effective_until) ? intent.effective_until : nil,
        active: intent.respond_to?(:active) ? intent.active : true,
        reason: intent.respond_to?(:reason) ? intent.reason : nil,
        prescribing_provider: intent.respond_to?(:prescribing_provider) ? intent.prescribing_provider : nil,
        notes: intent.respond_to?(:notes) ? intent.notes : nil
      }
      values.reject { |_key, value| value.nil? }
    end

    def target(engine, schedule_id, medication, at: nil, active: nil)
      rows = engine.query(DATASET, limit: 10_000)
      matches = if schedule_id && !schedule_id.to_s.empty?
                  rows.select { |row| row["schedule_id"] == schedule_id.to_s }
                else
                  rows.select do |row|
                    enabled = row["active"] == true || row["active"] == 1
                    interval = if at
                                 KnowledgeSDK::Schedule.active_during?(
                                   row["effective_from"], row["effective_until"],
                                   from: at, to: at
                                 )
                               else
                                 row["effective_until"].nil? || row["effective_until"].to_s.empty?
                               end
                    row["medication"].to_s.casecmp?(medication.to_s) && interval &&
                      (active.nil? || enabled == active)
                  end
                end
      raise RowNotFound, "medication schedule version was not found" if matches.empty?
      if matches.length > 1
        raise InvalidRow, "medication matches multiple schedule versions; provide schedule_id"
      end

      matches.first
    end

    def copy(row)
      VALUE_COLUMNS.each_with_object({}) do |column, values|
        values[column.to_sym] = row[column] if row.key?(column)
      end
    end

    def evolve_one(engine, prior, values, effective_from, provenance)
      engine.evolve(
        DATASET, match: { schedule_id: prior.fetch("schedule_id") },
        close_values: { effective_until: closing_date(prior, effective_from) },
        values: values, provenance: provenance
      )
    end

    def schedule_hash(value)
      KnowledgeSDK::Schedule.from_h(value).to_h
    rescue ArgumentError => error
      raise InvalidRow, "invalid schedule_json: #{error.message}"
    end

    def previous_day(value)
      (Date.iso8601(value.to_s) - 1).iso8601
    rescue ArgumentError
      raise InvalidRow, "effective date must be ISO 8601"
    end

    def closing_date(prior, value)
      starts = Date.iso8601(prior.fetch("effective_from").to_s)
      requested = Date.iso8601(value.to_s) - 1
      [starts, requested].max.iso8601
    rescue ArgumentError
      raise InvalidRow, "effective date must be ISO 8601"
    end
  end
end
