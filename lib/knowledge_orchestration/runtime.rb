# frozen_string_literal: true

require "pathname"
require "thread"

module KnowledgeOrchestration
  class Notification
    KINDS = %w[info briefing opportunity relationship goal proposal reminder digest warning].freeze

    attr_reader :id, :timestamp, :kind, :title, :message, :trace_id,
                :correlation_id, :source, :read

    def initialize(id:, timestamp:, kind:, title:, message:, trace_id:,
                   correlation_id:, source:, read: false)
      @id = AgentPlatform::Value.required_string(id, "notification id", maximum: 200)
      @timestamp = normalize_time(timestamp)
      @kind = kind.to_s
      raise InvalidEvent, "invalid notification kind" unless KINDS.include?(@kind)
      @title = AgentPlatform::Value.required_string(title, "notification title", maximum: 200)
      @message = AgentPlatform::Value.required_string(message, "notification message", maximum: 2_000)
      @trace_id = AgentPlatform::Value.required_string(trace_id, "trace id", maximum: 200)
      @correlation_id = AgentPlatform::Value.required_string(correlation_id, "correlation id", maximum: 200)
      @source = AgentPlatform::Value.required_string(source, "notification source", maximum: 200)
      @read = read == true
      freeze
    rescue ArgumentError => error
      raise InvalidEvent, error.message
    end

    def to_h
      {
        notification_id: id, timestamp: timestamp, kind: kind, title: title,
        message: message, trace_id: trace_id, correlation_id: correlation_id,
        source: source, read: read, executable: false
      }
    end

    def self.from_h(value)
      data = value.transform_keys(&:to_s)
      new(
        id: data.fetch("notification_id"), timestamp: data.fetch("timestamp"),
        kind: data.fetch("kind"), title: data.fetch("title"), message: data.fetch("message"),
        trace_id: data.fetch("trace_id"), correlation_id: data.fetch("correlation_id"),
        source: data.fetch("source"), read: data.fetch("read", false)
      )
    end

    private

    def normalize_time(value)
      parsed = value.respond_to?(:iso8601) ? value.iso8601(6) : value.to_s
      Time.iso8601(parsed).iso8601(6).freeze
    end
  end

  class NotificationStore
    def initialize(vault_root:, clock: nil, path: nil)
      @path = path || File.join(File.expand_path(vault_root.to_s), EventStore::RUNTIME, "notifications.jsonl")
      @clock = clock || -> { Time.now }
      @mutex = Mutex.new
    end

    def create(kind:, title:, message:, trace_id:, correlation_id:, source:)
      id = Stable.id("notification", kind, title, message, trace_id, correlation_id, source)
      @mutex.synchronize do
        existing = list.find { |notification| notification.id == id }
        return existing if existing

        notification = Notification.new(
          id: id, timestamp: @clock.call, kind: kind, title: title, message: message,
          trace_id: trace_id, correlation_id: correlation_id, source: source
        )
        AtomicFile.append_jsonl(@path, notification.to_h)
        notification
      end
    end

    def list(kind: nil)
      AtomicFile.read_jsonl(@path, error_class: InvalidEvent).map { |item| Notification.from_h(item) }
        .select { |notification| !kind || notification.kind == kind.to_s }
        .sort_by { |notification| [notification.timestamp, notification.id] }.freeze
    end
  end

  class WorkflowExecution
    STATUSES = %w[succeeded failed cancelled].freeze

    attr_reader :id, :workflow_id, :workflow_version, :workflow_digest, :event,
                :snapshot_digest, :trace_id, :status, :steps, :outputs,
                :started_at, :completed_at, :output_digest, :replay_of, :error

    def initialize(id:, workflow_id:, workflow_version:, workflow_digest:, event:,
                   snapshot_digest:, trace_id:, status:, steps:, outputs: {},
                   started_at:, completed_at:, output_digest:, replay_of: nil, error: nil)
      @id = id.to_s.freeze
      @workflow_id = workflow_id.to_s.freeze
      @workflow_version = workflow_version.to_s.freeze
      @workflow_digest = workflow_digest.to_s.freeze
      @event = event.is_a?(Event) ? event : Event.from_h(event)
      @snapshot_digest = snapshot_digest.to_s.freeze
      @trace_id = trace_id.to_s.freeze
      @status = status.to_s.freeze
      raise WorkflowExecutionFailed, "invalid workflow status" unless STATUSES.include?(@status)
      @steps = AgentPlatform::Value.immutable(steps)
      @outputs = AgentPlatform::Value.immutable(outputs)
      @started_at = normalize_time(started_at)
      @completed_at = normalize_time(completed_at)
      @output_digest = output_digest.to_s.freeze
      @replay_of = replay_of && replay_of.to_s.freeze
      @error = error && AgentPlatform::Value.immutable(error)
      freeze
    end

    def to_h
      {
        execution_id: id, workflow_id: workflow_id, workflow_version: workflow_version,
        workflow_digest: workflow_digest, input_event: event.to_h,
        snapshot_digest: snapshot_digest, trace_id: trace_id, status: status,
        steps: steps, outputs: outputs, started_at: started_at, completed_at: completed_at,
        output_digest: output_digest, replay_of: replay_of, error: error
      }.reject { |_key, value| value.nil? }
    end

    def timeline
      {
        execution_id: id, workflow_id: workflow_id, workflow_version: workflow_version,
        input_event_id: event.id, input_event_type: event.type,
        snapshot_digest: snapshot_digest, trace_id: trace_id, status: status,
        started_at: started_at, completed_at: completed_at, output_digest: output_digest,
        replay_of: replay_of,
        steps: steps.map do |step|
          {
            step_id: step["step_id"], capability_id: step["capability_id"],
            capability_version: step["capability_version"], status: step["status"],
            attempts: step["attempts"], duration_ms: step["duration_ms"],
            cache_hit: step["cache_hit"], artifact_id: step["artifact_id"],
            output_digest: step["output_digest"], error_code: step.dig("error", "code")
          }.reject { |_key, value| value.nil? }
        end
      }.reject { |_key, value| value.nil? }
    end

    def self.from_h(value)
      data = value.transform_keys(&:to_s)
      new(
        id: data.fetch("execution_id"), workflow_id: data.fetch("workflow_id"),
        workflow_version: data.fetch("workflow_version"), workflow_digest: data.fetch("workflow_digest"),
        event: data.fetch("input_event"), snapshot_digest: data.fetch("snapshot_digest"),
        trace_id: data.fetch("trace_id"), status: data.fetch("status"),
        steps: data.fetch("steps"), outputs: data.fetch("outputs", {}),
        started_at: data.fetch("started_at"), completed_at: data.fetch("completed_at"),
        output_digest: data.fetch("output_digest"), replay_of: data["replay_of"], error: data["error"]
      )
    end

    private

    def normalize_time(value)
      parsed = value.respond_to?(:iso8601) ? value.iso8601(6) : value.to_s
      Time.iso8601(parsed).iso8601(6).freeze
    end
  end

  class WorkflowHistoryStore
    def initialize(vault_root:)
      @root = Pathname.new(vault_root).join(EventStore::RUNTIME, "executions")
    end

    def write(execution)
      AtomicFile.write_json(path_for(execution.id), execution.to_h)
      execution
    end

    def fetch(execution_id)
      path = path_for(execution_id)
      raise WorkflowNotFound, "workflow execution not found: #{execution_id}" unless path.file?

      WorkflowExecution.from_h(AtomicFile.read_json(path, error_class: WorkflowExecutionFailed))
    end

    def list(workflow_id: nil)
      return [] unless @root.directory?

      Dir[@root.join("workflow-run_*.json").to_s].sort.map { |path| WorkflowExecution.from_h(AtomicFile.read_json(path)) }
        .select { |execution| !workflow_id || execution.workflow_id == workflow_id.to_s }
        .sort_by { |execution| [execution.started_at, execution.id] }.freeze
    end

    private

    def path_for(execution_id)
      value = execution_id.to_s
      unless value.match?(/\Aworkflow-run_[0-9A-HJKMNP-TV-Z]{26}\z/)
        raise WorkflowNotFound, "invalid workflow execution id"
      end

      @root.join("#{value}.json")
    end
  end

  class DurableJob
    TERMINAL = %w[succeeded failed cancelled].freeze

    attr_reader :data

    def initialize(data)
      @data = AgentPlatform::Value.immutable(data)
      freeze
    end

    def id
      data.fetch("job_id")
    end

    def status
      data.fetch("status")
    end

    def terminal?
      TERMINAL.include?(status)
    end

    def to_h
      data
    end
  end

  class DurableJobManager
    def initialize(vault_root:, clock: nil, threaded: false)
      @root = Pathname.new(vault_root).join(EventStore::RUNTIME, "jobs")
      @clock = clock || -> { Time.now }
      @threaded = threaded == true
      @mutex = Mutex.new
    end

    def submit(event:, workflow:, force: false, &work)
      raise ArgumentError, "job work is required" unless work
      job_id = Stable.id("workflow-job", event.id, workflow.id, workflow.version)
      existing = fetch(job_id, required: false)
      return existing if existing&.terminal? && !force

      job = DurableJob.new(
        "job_id" => job_id, "status" => "queued", "progress" => 0,
        "event_id" => event.id, "workflow_id" => workflow.id,
        "workflow_version" => workflow.version, "trace_id" => event.trace_id,
        "retry_state" => {}, "result" => nil, "error" => nil,
        "created_at" => @clock.call.iso8601(6), "updated_at" => @clock.call.iso8601(6),
        "resumable" => true
      )
      persist(job)
      runner = -> { run(job, &work) }
      @threaded ? Thread.new(&runner) : runner.call
      fetch(job_id)
    end

    def update(job_id, attributes)
      @mutex.synchronize do
        current = fetch(job_id).to_h
        return DurableJob.new(current) if current.fetch("status") == "cancelled"

        updated = AgentPlatform::Value.mutable(current).merge(attributes.transform_keys(&:to_s))
        updated["updated_at"] = @clock.call.iso8601(6)
        persist(DurableJob.new(updated))
      end
    end

    def cancel(job_id)
      @mutex.synchronize do
        current = fetch(job_id)
        return current if current.terminal?

        updated = AgentPlatform::Value.mutable(current.to_h).merge(
          "status" => "cancelled", "progress" => current.to_h.fetch("progress"),
          "updated_at" => @clock.call.iso8601(6), "resumable" => false
        )
        persist(DurableJob.new(updated))
      end
    end

    def fetch(job_id, required: true)
      path = path_for(job_id)
      if !path.file?
        raise JobNotFound, "workflow job not found: #{job_id}" if required
        return nil
      end

      DurableJob.new(AtomicFile.read_json(path, error_class: WorkflowExecutionFailed))
    end

    def list(status: nil)
      return [] unless @root.directory?

      Dir[@root.join("workflow-job_*.json").to_s].sort.map do |path|
        DurableJob.new(AtomicFile.read_json(path, error_class: WorkflowExecutionFailed))
      end.select { |job| !status || job.status == status.to_s }
        .sort_by { |job| [job.to_h.fetch("created_at"), job.id] }.freeze
    end

    def resumable
      list.select { |job| %w[queued running failed].include?(job.status) && job.to_h.fetch("resumable") }.freeze
    end

    private

    def run(job)
      running = update(job.id, status: "running", progress: 1)
      return running if running.status == "cancelled"

      result = yield(lambda do |progress, retry_state = nil|
        attributes = { progress: Integer(progress) }
        attributes[:retry_state] = retry_state if retry_state
        update(job.id, attributes)
      end)
      update(job.id, status: "succeeded", progress: 100,
             result: { "execution_id" => result.id, "output_digest" => result.output_digest },
             resumable: false)
    rescue StandardError => error
      update(job.id, status: "failed", progress: 100, resumable: true,
             error: { "code" => error.class.name.split("::").last, "message" => safe_message(error.message) })
    end

    def persist(job)
      AtomicFile.write_json(path_for(job.id), job.to_h)
      job
    end

    def path_for(job_id)
      value = job_id.to_s
      raise JobNotFound, "invalid workflow job id" unless value.match?(/\Aworkflow-job_[0-9A-HJKMNP-TV-Z]{26}\z/)

      @root.join("#{value}.json")
    end

    def safe_message(value)
      value.to_s.gsub(%r{(?:/[^\s:]+)+}, "[path]")[0, 500]
    end
  end

  class Observability
    def initialize(history:, event_store:, jobs:, cache:)
      @history = history
      @event_store = event_store
      @jobs = jobs
      @cache = cache
    end

    def workflow_timeline(execution_id)
      @history.fetch(execution_id).timeline
    end

    def event_timeline(event_id)
      event = @event_store.fetch(event_id)
      executions = @history.list.select { |execution| execution.event.id == event.id }
      {
        event_id: event.id, sequence: event.sequence, timestamp: event.timestamp,
        source: event.source, type: event.type, correlation_id: event.correlation_id,
        causation_id: event.causation_id, trace_id: event.trace_id, version: event.version,
        workflow_executions: executions.map { |execution| execution.timeline }
      }.reject { |_key, value| value.nil? }
    end

    def metrics
      executions = @history.list
      step_durations = executions.flat_map { |execution| execution.steps.map { |step| step["duration_ms"].to_f } }
      {
        workflows: executions.length, succeeded: executions.count { |execution| execution.status == "succeeded" },
        failed: executions.count { |execution| execution.status == "failed" },
        jobs: @jobs.list.length, average_step_latency_ms: step_durations.empty? ? 0.0 :
          (step_durations.sum / step_durations.length).round(3),
        retries: executions.sum { |execution| execution.steps.sum { |step| [step["attempts"].to_i - 1, 0].max } },
        cache: @cache.metrics
      }
    end
  end
end
