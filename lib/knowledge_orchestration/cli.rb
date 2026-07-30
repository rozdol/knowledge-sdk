# frozen_string_literal: true

require "json"
require "optparse"

module KnowledgeOrchestration
  class CLI
    def initialize(group:, argv:, out:, err:, orchestrator:)
      @group = group.to_s
      @argv = argv.dup
      @out = out
      @err = err
      @orchestrator = orchestrator
    end

    def run
      case @group
      when "events" then events_command
      when "workflow" then workflow_command
      when "scheduler" then scheduler_command
      when "notifications" then notifications_command
      when "cache" then cache_command
      else raise Error, "unknown orchestration command group #{@group.inspect}"
      end
      0
    rescue OptionParser::ParseError, JSON::ParserError, ArgumentError, Error => error
      @err.puts(JSON.generate(error: error.message, error_class: error.class.name))
      2
    end

    private

    def events_command
      command = @argv.shift
      case command
      when "list"
        options = { limit: nil, type: nil }
        OptionParser.new do |parser|
          parser.on("--type TYPE") { |value| options[:type] = value }
          parser.on("--limit N", Integer) { |value| options[:limit] = value }
        end.parse!(@argv)
        filter = options[:type] && EventFilter.new(types: [options[:type]])
        emit(events: @orchestrator.event_bus.store.events(filter: filter, limit: options[:limit]).map(&:to_h))
      when "publish"
        type = @argv.shift || raise(InvalidEvent, "event type is required")
        payload = parse_object(@argv.shift || "{}")
        emit(@orchestrator.publish(type: type, source: "local-cli", payload: payload).to_h)
      when "replay"
        event_id = @argv.shift || raise(EventNotFound, "event ID is required")
        emit(replayed: true, executions: @orchestrator.replay_event(event_id).map(&:timeline))
      when "explain"
        event_id = @argv.shift || raise(EventNotFound, "event ID is required")
        emit(@orchestrator.observability.event_timeline(event_id))
      when "dead-letters"
        emit(dead_letters: @orchestrator.event_bus.dead_letters.list)
      else
        @out.puts("Usage: kg events list|publish|replay|explain|dead-letters")
      end
    end

    def workflow_command
      command = @argv.shift
      case command
      when "list"
        emit(workflows: @orchestrator.workflow_registry.list.map(&:to_h))
      when "run"
        workflow_id = @argv.shift || raise(WorkflowNotFound, "workflow ID is required")
        payload = parse_object(@argv.shift || "{}")
        event = @orchestrator.run_workflow(workflow_id, payload: payload)
        jobs = @orchestrator.jobs.list.select { |job| job.to_h.fetch("event_id") == event.id }
        emit(event: event.to_h, jobs: jobs.map(&:to_h))
      when "replay"
        execution_id = @argv.shift || raise(WorkflowNotFound, "execution ID is required")
        emit(replayed: true, execution: @orchestrator.replay_execution(execution_id).timeline)
      when "trace"
        execution_id = @argv.shift || raise(WorkflowNotFound, "execution ID is required")
        emit(@orchestrator.observability.workflow_timeline(execution_id))
      when "cancel"
        job_id = @argv.shift || raise(JobNotFound, "job ID is required")
        emit(@orchestrator.jobs.cancel(job_id).to_h)
      when "jobs"
        emit(jobs: @orchestrator.jobs.list.map(&:to_h))
      when "resume"
        emit(jobs: @orchestrator.resume_jobs.map(&:to_h))
      when "metrics"
        emit(@orchestrator.observability.metrics)
      else
        @out.puts("Usage: kg workflow list|run|replay|trace|cancel|jobs|resume|metrics")
      end
    end

    def scheduler_command
      command = @argv.shift
      case command
      when "list"
        emit(schedules: @orchestrator.scheduler.schedules.map(&:to_h))
      when "run"
        options = { at: Time.now, schedule_id: nil, force: false }
        OptionParser.new do |parser|
          parser.on("--at TIME") { |value| options[:at] = Time.iso8601(value) }
          parser.on("--schedule ID") { |value| options[:schedule_id] = value }
          parser.on("--force") { options[:force] = true }
        end.parse!(@argv)
        events = @orchestrator.scheduler.run(**options)
        emit(events: events.map(&:to_h))
      else
        @out.puts("Usage: kg scheduler list|run [--at TIME] [--schedule ID] [--force]")
      end
    end

    def notifications_command
      command = @argv.shift
      case command
      when "list", nil then emit(notifications: @orchestrator.notifications.list.map(&:to_h))
      else @out.puts("Usage: kg notifications list")
      end
    end

    def cache_command
      command = @argv.shift
      case command
      when "list"
        emit(artifacts: @orchestrator.cache.list.map(&:summary), metrics: @orchestrator.cache.metrics)
      when "explain"
        artifact_id = @argv.shift || raise(CacheError, "artifact ID is required")
        emit(@orchestrator.cache.fetch_artifact(artifact_id).summary)
      when "graph"
        emit(@orchestrator.cache.dependency_graph.to_h)
      else
        @out.puts("Usage: kg cache list|explain|graph")
      end
    end

    def parse_object(value)
      parsed = JSON.parse(value.to_s)
      raise ArgumentError, "payload must be a JSON object" unless parsed.is_a?(Hash)

      parsed
    end

    def emit(value)
      @out.puts(JSON.pretty_generate(AgentPlatform::Value.canonical(value)))
    end
  end
end
