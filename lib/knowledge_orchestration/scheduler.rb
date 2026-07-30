# frozen_string_literal: true

require "yaml"

module KnowledgeOrchestration
  class CronExpression
    FIELD_RANGES = [[0, 59], [0, 23], [1, 31], [1, 12], [0, 6]].freeze

    attr_reader :expression

    def initialize(expression)
      @expression = expression.to_s.strip.freeze
      parts = @expression.split(/\s+/)
      raise InvalidSchedule, "cron expression must have five fields" unless parts.length == 5

      @fields = parts.each_with_index.map { |part, index| parse_field(part, *FIELD_RANGES[index]) }.freeze
      freeze
    end

    def match?(time)
      values = [time.min, time.hour, time.day, time.month, time.wday]
      @fields.each_with_index.all? { |allowed, index| allowed.include?(values[index]) }
    end

    private

    def parse_field(field, minimum, maximum)
      values = field.split(",").flat_map do |component|
        range_part, step_part = component.split("/", 2)
        step = step_part ? Integer(step_part) : 1
        raise InvalidSchedule, "cron step must be positive" unless step.positive?
        first, last = if range_part == "*"
                        [minimum, maximum]
                      elsif range_part.include?("-")
                        range_part.split("-", 2).map { |item| Integer(item) }
                      else
                        value = Integer(range_part)
                        [value, value]
                      end
        unless first.between?(minimum, maximum) && last.between?(minimum, maximum) && first <= last
          raise InvalidSchedule, "cron value is out of range"
        end
        (first..last).step(step).to_a
      end
      values.uniq.sort.freeze
    rescue ArgumentError
      raise InvalidSchedule, "invalid cron field #{field.inspect}"
    end
  end

  class ScheduleDefinition
    attr_reader :id, :cron, :event_type, :workflow_id, :payload, :enabled,
                :description

    def initialize(id:, cron:, event_type:, workflow: nil, payload: {}, enabled: true,
                   description: nil)
      @id = id.to_s
      raise InvalidSchedule, "invalid schedule id" unless @id.match?(/\A[a-z][a-z0-9_-]*\z/)
      @cron = cron.is_a?(CronExpression) ? cron : CronExpression.new(cron)
      @event_type = event_type.to_s
      raise InvalidSchedule, "invalid scheduled event type" unless @event_type.match?(Event::TYPE_PATTERN)
      @workflow_id = workflow && workflow.to_s.freeze
      raise InvalidSchedule, "schedule payload must be an object" unless payload.is_a?(Hash)
      @payload = AgentPlatform::Value.immutable(payload)
      @enabled = enabled == true
      @description = description && description.to_s.freeze
      freeze
    end

    def due?(time)
      enabled && cron.match?(time)
    end

    def to_h
      {
        id: id, cron: cron.expression, event_type: event_type,
        workflow: workflow_id, payload: payload, enabled: enabled,
        description: description
      }.reject { |_key, value| value.nil? }
    end
  end

  class ScheduleLoader
    def load(path)
      payload = YAML.safe_load(File.read(path.to_s), aliases: false)
      raise InvalidSchedule, "schedule file must contain an object" unless payload.is_a?(Hash)
      data = payload.transform_keys(&:to_s)
      raise InvalidSchedule, "unsupported schedule schema" unless data.fetch("schema_version", 1) == 1

      Array(data.fetch("schedules")).map do |item|
        values = item.transform_keys(&:to_s)
        ScheduleDefinition.new(
          id: values.fetch("id"), cron: values.fetch("cron"),
          event_type: values.fetch("event_type"), workflow: values["workflow"],
          payload: values.fetch("payload", {}), enabled: values.fetch("enabled", true),
          description: values["description"]
        )
      end.freeze
    rescue Psych::Exception => error
      raise InvalidSchedule, "invalid schedule YAML: #{error.message}"
    rescue KeyError => error
      raise InvalidSchedule, "schedule is missing #{error.key}"
    end
  end

  class SchedulerState
    def initialize(vault_root:, path: nil)
      @path = path || File.join(File.expand_path(vault_root.to_s), EventStore::RUNTIME, "scheduler_state.json")
    end

    def processed?(schedule_id, slot)
      state.fetch("processed_slots", []).include?(key(schedule_id, slot))
    end

    def mark(schedule_id, slot, event_id)
      current = state
      entries = current.fetch("processed_slots", []) + [key(schedule_id, slot)]
      events = current.fetch("events", {}).merge(key(schedule_id, slot) => event_id.to_s)
      AtomicFile.write_json(@path, "processed_slots" => entries.uniq.sort, "events" => events)
    end

    private

    def state
      return { "processed_slots" => [], "events" => {} } unless File.file?(@path)

      AtomicFile.read_json(@path, error_class: InvalidSchedule)
    end

    def key(schedule_id, slot)
      "#{schedule_id}@#{slot}"
    end
  end

  class Scheduler
    attr_reader :schedules

    def initialize(schedules:, event_bus:, vault_root:, clock: nil, state: nil)
      @schedules = Array(schedules).sort_by(&:id).freeze
      raise InvalidSchedule, "schedule ids must be unique" unless @schedules.map(&:id).uniq.length == @schedules.length
      @event_bus = event_bus
      @clock = clock || -> { Time.now }
      @state = state || SchedulerState.new(vault_root: vault_root)
    end

    def due(at: @clock.call)
      schedules.select { |schedule| schedule.due?(at) }.freeze
    end

    def run(at: @clock.call, schedule_id: nil, force: false)
      selected = schedule_id ? [fetch(schedule_id)] : due(at: at)
      selected.each_with_object([]) do |schedule, result|
        slot = at.strftime("%Y-%m-%dT%H:%M")
        next if !force && @state.processed?(schedule.id, slot)

        payload = AgentPlatform::Value.mutable(schedule.payload)
        payload["_workflow"] = schedule.workflow_id if schedule.workflow_id
        payload["schedule_id"] = schedule.id
        payload["scheduled_for"] = at.iso8601
        payload["as_of"] ||= at.to_date.iso8601
        event = @event_bus.publish(
          type: schedule.event_type, source: "scheduler:#{schedule.id}", payload: payload,
          correlation_id: Stable.id("correlation", schedule.id, slot),
          trace_id: Stable.id("trace", schedule.id, slot), timestamp: at
        )
        @state.mark(schedule.id, slot, event.id)
        result << event
      end.freeze
    end

    def fetch(schedule_id)
      schedules.find { |schedule| schedule.id == schedule_id.to_s } ||
        raise(ScheduleNotFound, "schedule not found: #{schedule_id}")
    end
  end
end
