# frozen_string_literal: true

require "fileutils"
require "json"
require "pathname"
require "time"

module KnowledgeGraph
  class AuditLog
    attr_reader :path

    def initialize(vault_root:, clock: nil, id_generator: nil, actor_id: nil, run_id: nil)
      @vault_root = Pathname.new(vault_root)
      @path = @vault_root.join("_System/KnowledgeGraph/Runtime/audit.jsonl")
      @clock = clock || -> { Time.now }
      @id_generator = id_generator || IdGenerator.new(clock: @clock)
      @actor_id = actor_id
      @run_id = run_id
    end

    def record(intent:, fingerprint:, result: nil, error: nil, rollback:, duration_ms:)
      event = {
        "id" => @id_generator.generate("audit"),
        "timestamp" => @clock.call.iso8601,
        "fingerprint" => fingerprint,
        "intent" => ReceiptStore.new(vault_root: @vault_root).intent_payload(intent),
        "intent_type" => intent.intent_type,
        "entity_ids" => result ? result.entity_ids : [],
        "result" => error ? "failure" : "success",
        "duration_ms" => duration_ms,
        "rollback" => !!rollback,
        "replayed" => result ? result.replayed : false,
        "changed_paths" => result ? result.changed_paths : [],
        "value" => result&.value,
        "run_id" => @run_id,
        "actor_id" => @actor_id
      }
      event["error"] = { "class" => error.class.name, "message" => error.message } if error
      append(event)
      event.fetch("id")
    end

    def events
      return [] unless path.file?

      path.each_line.map { |line| JSON.parse(line) }
    rescue JSON::ParserError => error
      raise AuditError, "invalid audit log #{path}: #{error.message}"
    end

    def find(event_id)
      events.reverse_each.find { |event| event["id"] == event_id.to_s } ||
        raise(EntityNotFound, "audit event not found: #{event_id}")
    end

    private

    def append(event)
      FileUtils.mkdir_p(path.dirname)
      File.open(path, File::WRONLY | File::APPEND | File::CREAT, 0o600) do |file|
        file.flock(File::LOCK_EX)
        file.write(JSON.generate(event) + "\n")
        file.flush
        file.fsync
      ensure
        file.flock(File::LOCK_UN) rescue nil
      end
    rescue SystemCallError => error
      raise AuditError, "could not append audit event: #{error.message}"
    end
  end
end
