# frozen_string_literal: true

require "thread"
require "timeout"

module AgentPlatform
  class Job
    attr_reader :id, :agent_id, :capability_id, :created_at, :finished_at

    def initialize(id:, agent_id:, capability_id:, created_at:, clock: nil)
      @id = id.to_s.freeze
      @agent_id = agent_id.to_s.freeze
      @capability_id = capability_id.to_s.freeze
      @created_at = created_at.iso8601.freeze
      @clock = clock || -> { Time.now }
      @mutex = Mutex.new
      @condition = ConditionVariable.new
      @status = "queued"
      @progress = 0
      @result = nil
      @error = nil
    end

    def start
      transition("running", 1)
    end

    def complete(result)
      @mutex.synchronize do
        @status = "succeeded"
        @finished_at = @clock.call
        @progress = 100
        @result = result
        @condition.broadcast
      end
    end

    def fail(error)
      @mutex.synchronize do
        @status = "failed"
        @finished_at = @clock.call
        @progress = 100
        safe_message = error.is_a?(AgentPlatform::Error) ? error.message : "asynchronous capability failed"
        @error = { code: error.class.name.split("::").last, message: safe_message }
        @condition.broadcast
      end
    end

    def wait(timeout_seconds = nil)
      @mutex.synchronize do
        unless terminal?
          @condition.wait(@mutex, timeout_seconds)
        end
        terminal?
      end
    end

    def terminal?
      %w[succeeded failed].include?(@status)
    end

    def to_h(include_result: true)
      @mutex.synchronize do
        value = {
          job_id: id, status: @status, progress: @progress,
          capability_id: capability_id, created_at: created_at
        }
        value[:result] = @result.respond_to?(:to_h) ? @result.to_h : @result if include_result && @result
        value[:error] = @error if @error
        Value.immutable(value)
      end
    end

    private

    def transition(status, progress)
      @mutex.synchronize do
        @status = status
        @progress = progress
      end
    end
  end

  class JobManager
    def initialize(clock: nil, id_generator: nil, threaded: true, limit: nil, per_agent_limit: nil, ttl_seconds: nil)
      @clock = clock || -> { Time.now }
      @id_generator = id_generator || KnowledgeGraph::IdGenerator.new(clock: @clock)
      @threaded = !!threaded
      @limit, @per_agent_limit, @ttl_seconds = limit, per_agent_limit, ttl_seconds
      @jobs = {}
      @mutex = Mutex.new
    end

    def submit(agent_id:, capability_id:, &work)
      raise ArgumentError, "job work is required" unless work

      job = Job.new(
        id: @id_generator.generate("job"), agent_id: agent_id,
        capability_id: capability_id, created_at: @clock.call, clock: @clock
      )
      @mutex.synchronize do
        prune!
        if (@limit && @jobs.length >= @limit) ||
           (@per_agent_limit && @jobs.values.count { |item| item.agent_id == agent_id.to_s } >= @per_agent_limit)
          raise ExecutionFailed, "read job capacity reached"
        end
        @jobs[job.id] = job
      end
      runner = lambda do
        job.start
        job.complete(work.call)
      rescue StandardError => error
        job.fail(error)
      end
      @threaded ? Thread.new(&runner) : runner.call
      job
    end

    def fetch(job_id, agent_id: nil)
      job = @mutex.synchronize { prune!; @jobs[job_id.to_s] }
      raise JobNotFound, "job not found" unless job
      raise PolicyDenied, "job belongs to another agent" if agent_id && job.agent_id != agent_id.to_s

      job
    end

    def wait(job_id, agent_id:, timeout_ms: 30_000)
      job = fetch(job_id, agent_id: agent_id)
      job.wait(timeout_ms.to_f / 1_000.0)
      job.to_h
    end

    def remove_agent(agent_id)
      @mutex.synchronize { @jobs.delete_if { |_id, job| job.agent_id == agent_id.to_s } }
    end

    private

    def prune!
      return unless @ttl_seconds

      cutoff = @clock.call - @ttl_seconds
      @jobs.delete_if { |_id, job| job.finished_at && job.finished_at <= cutoff }
    end
  end
end
