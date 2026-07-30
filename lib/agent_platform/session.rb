# frozen_string_literal: true

require "thread"
require "time"

module AgentPlatform
  class MemoryReference
    ID_PATTERN = /\A[a-z][a-z0-9-]*_[0-9A-HJKMNP-TV-Z]{26}\z/.freeze

    attr_reader :kind, :reference_id, :label

    def initialize(kind:, reference_id:, label: nil)
      @kind = Value.required_string(kind, "memory reference kind", maximum: 80)
      @reference_id = Value.required_string(reference_id, "memory reference id", maximum: 200)
      unless @reference_id.match?(ID_PATTERN)
        raise ArgumentError, "working memory stores immutable references only"
      end
      @label = label && Value.required_string(label, "memory reference label", maximum: 200)
      freeze
    end

    def to_h
      { kind: kind, reference_id: reference_id, label: label }.reject { |_key, value| value.nil? }
    end
  end

  class WorkingMemory
    DEFAULT_LIMIT = 32
    attr_reader :references, :limit

    def initialize(references: [], limit: DEFAULT_LIMIT)
      @limit = Integer(limit)
      raise ArgumentError, "working memory limit must be between 1 and 128" unless @limit.between?(1, 128)

      @references = Array(references).map do |item|
        item.is_a?(MemoryReference) ? item : MemoryReference.new(**symbolize(item))
      end
      raise ArgumentError, "working memory exceeds its bound" if @references.length > @limit

      @references = @references.freeze
      freeze
    end

    def add(reference)
      item = reference.is_a?(MemoryReference) ? reference : MemoryReference.new(**symbolize(reference))
      combined = (references + [item]).uniq { |entry| [entry.kind, entry.reference_id] }.last(limit)
      self.class.new(references: combined, limit: limit)
    end

    def to_h
      { limit: limit, references: references.map(&:to_h) }
    end

    private

    def symbolize(value)
      value.each_with_object({}) { |(key, item), result| result[key.to_sym] = item }
    end
  end

  class Session
    attr_reader :id, :conversation_id, :agent_id, :selected_entity_ids,
                :current_project_id, :current_company_id, :time_window,
                :language, :working_memory, :active_proposal_id, :preferences,
                :created_at, :expires_at, :version

    def initialize(id:, conversation_id:, agent_id:, created_at:, expires_at:,
                   selected_entity_ids: [], current_project_id: nil, current_company_id: nil,
                   time_window: nil, language: "und", working_memory: WorkingMemory.new,
                   active_proposal_id: nil, preferences: {}, version: 1)
      @id = validated_reference(id, "session id")
      @conversation_id = Value.required_string(conversation_id, "conversation id", maximum: 500)
      @agent_id = Value.required_string(agent_id, "agent id", maximum: 200)
      @selected_entity_ids = Array(selected_entity_ids).map do |item|
        validated_reference(item, "selected entity id")
      end.uniq
      raise ArgumentError, "session may select at most 100 entities" if @selected_entity_ids.length > 100
      @selected_entity_ids = @selected_entity_ids.freeze
      @current_project_id = optional(current_project_id)
      @current_company_id = optional(current_company_id)
      @time_window = time_window && bounded_hash(time_window, "time_window", 4_096)
      @language = Value.required_string(language, "language", maximum: 40)
      @working_memory = working_memory.is_a?(WorkingMemory) ? working_memory : WorkingMemory.new(**working_memory)
      @active_proposal_id = optional(active_proposal_id)
      @preferences = bounded_hash(preferences || {}, "preferences", 16_384)
      @created_at = normalize_time(created_at)
      @expires_at = normalize_time(expires_at)
      @version = Integer(version)
      raise ArgumentError, "session expiry must be after creation" unless Time.iso8601(@expires_at) > Time.iso8601(@created_at)
      freeze
    end

    def expired?(now = Time.now)
      Time.iso8601(expires_at) <= now
    end

    def with(**changes)
      values = to_h
      values.delete(:id)
      values.delete(:created_at)
      values.delete(:version)
      memory = changes.key?(:working_memory) ? changes.delete(:working_memory) : working_memory
      self.class.new(
        **values.merge(changes).merge(
          id: id, created_at: created_at, version: version + 1, working_memory: memory
        )
      )
    end

    def to_h
      {
        id: id, conversation_id: conversation_id, agent_id: agent_id,
        selected_entity_ids: selected_entity_ids, current_project_id: current_project_id,
        current_company_id: current_company_id, time_window: time_window,
        language: language, working_memory: working_memory,
        active_proposal_id: active_proposal_id, preferences: preferences,
        created_at: created_at, expires_at: expires_at, version: version
      }
    end

    private

    def optional(value)
      value && validated_reference(value, "session reference")
    end

    def validated_reference(value, field)
      string = Value.required_string(value, field, maximum: 200)
      raise ArgumentError, "#{field} must be an immutable ID" unless string.match?(MemoryReference::ID_PATTERN)

      string
    end

    def bounded_hash(value, field, maximum_bytes)
      raise ArgumentError, "#{field} must be an object" unless value.is_a?(Hash)
      raise ArgumentError, "#{field} is too large" if Value.canonical_json(value).bytesize > maximum_bytes

      Value.immutable(value)
    end

    def normalize_time(value)
      time = value.is_a?(Time) ? value : Time.iso8601(value.to_s)
      time.iso8601.freeze
    end
  end

  class SessionStore
    DEFAULT_TTL = 3_600
    DEFAULT_LIMIT = 10_000

    def initialize(clock: nil, id_generator: nil, limit: DEFAULT_LIMIT)
      @clock = clock || -> { Time.now }
      @id_generator = id_generator || KnowledgeGraph::IdGenerator.new(clock: @clock)
      @limit = Integer(limit)
      raise ArgumentError, "session limit must be positive" unless @limit.positive?
      @sessions = {}
      @mutex = Mutex.new
    end

    def create(conversation_id:, agent_id:, ttl_seconds: DEFAULT_TTL, **attributes)
      ttl = Integer(ttl_seconds)
      raise ArgumentError, "session TTL must be between 1 and 86400 seconds" unless ttl.between?(1, 86_400)

      now = @clock.call
      session = Session.new(
        id: @id_generator.generate("session"), conversation_id: conversation_id,
        agent_id: agent_id, created_at: now, expires_at: now + ttl, **attributes
      )
      @mutex.synchronize do
        prune_expired!
        raise ExecutionFailed, "session capacity exceeded" if @sessions.length >= @limit

        @sessions[session.id] = session
      end
      session
    end

    def fetch(session_id, agent_id: nil)
      session = @mutex.synchronize { @sessions[session_id.to_s] }
      raise SessionNotFound, "session not found" unless session
      raise PolicyDenied, "session belongs to another agent" if agent_id && session.agent_id != agent_id.to_s
      if session.expired?(@clock.call)
        @mutex.synchronize { @sessions.delete(session.id) }
        raise SessionExpired, "session expired"
      end
      session
    end

    def update(session_id, agent_id:, **changes)
      @mutex.synchronize do
        current = @sessions[session_id.to_s]
        raise SessionNotFound, "session not found" unless current
        raise PolicyDenied, "session belongs to another agent" unless current.agent_id == agent_id.to_s
        raise SessionExpired, "session expired" if current.expired?(@clock.call)

        @sessions[current.id] = current.with(**changes)
      end
    end

    def size
      @mutex.synchronize do
        prune_expired!
        @sessions.length
      end
    end

    private

    def prune_expired!
      now = @clock.call
      @sessions.delete_if { |_id, session| session.expired?(now) }
    end
  end
end
