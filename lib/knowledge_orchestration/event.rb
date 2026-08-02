# frozen_string_literal: true

require "set"
require "thread"

module KnowledgeOrchestration
  class Event
    ID_PATTERN = /\Aevent_[0-9A-HJKMNP-TV-Z]{26}\z/.freeze
    TYPE_PATTERN = /\A[A-Z][A-Za-z0-9]{1,99}\z/.freeze

    attr_reader :id, :timestamp, :source, :type, :payload, :correlation_id,
                :causation_id, :trace_id, :version, :sequence

    def initialize(id:, timestamp:, source:, type:, payload:, correlation_id:,
                   causation_id:, trace_id:, version: 1, sequence: nil)
      @id = required(id, "event id")
      raise InvalidEvent, "invalid event id" unless @id.match?(ID_PATTERN)

      @timestamp = normalize_time(timestamp)
      @source = required(source, "event source", maximum: 200)
      @type = required(type, "event type", maximum: 100)
      raise InvalidEvent, "invalid event type" unless @type.match?(TYPE_PATTERN)
      raise InvalidEvent, "event payload must be an object" unless payload.is_a?(Hash)

      @payload = AgentPlatform::Value.immutable(payload)
      @correlation_id = required(correlation_id, "correlation id", maximum: 200)
      @causation_id = causation_id && required(causation_id, "causation id", maximum: 200)
      @trace_id = required(trace_id, "trace id", maximum: 200)
      @version = Integer(version)
      raise InvalidEvent, "event version must be positive" unless @version.positive?
      @sequence = sequence && Integer(sequence)
      raise InvalidEvent, "event sequence must be positive" if @sequence && !@sequence.positive?
      freeze
    rescue ArgumentError, TypeError => error
      raise InvalidEvent, error.message
    end

    def with_sequence(value)
      self.class.new(
        id: id, timestamp: timestamp, source: source, type: type, payload: payload,
        correlation_id: correlation_id, causation_id: causation_id,
        trace_id: trace_id, version: version, sequence: value
      )
    end

    def to_h
      {
        event_id: id, timestamp: timestamp, source: source, type: type,
        payload: payload, correlation_id: correlation_id, causation_id: causation_id,
        trace_id: trace_id, version: version, sequence: sequence
      }.reject { |_key, value| value.nil? }
    end

    def self.from_h(value)
      data = value.transform_keys(&:to_s)
      new(
        id: data.fetch("event_id"), timestamp: data.fetch("timestamp"),
        source: data.fetch("source"), type: data.fetch("type"),
        payload: data.fetch("payload"), correlation_id: data.fetch("correlation_id"),
        causation_id: data["causation_id"], trace_id: data.fetch("trace_id"),
        version: data.fetch("version"), sequence: data["sequence"]
      )
    rescue KeyError => error
      raise InvalidEvent, "event is missing #{error.key}"
    end

    private

    def required(value, field, maximum: 500)
      AgentPlatform::Value.required_string(value, field, maximum: maximum)
    end

    def normalize_time(value)
      parsed = value.is_a?(Time) ? value : Time.iso8601(value.to_s)
      parsed.iso8601(6).freeze
    rescue ArgumentError
      raise InvalidEvent, "event timestamp must be ISO 8601"
    end
  end

  class EventRegistry
    DEFAULT_TYPES = %w[
      GraphChanged ProposalApproved ProposalRejected GoalCreated GoalArchived
      MeetingImported TranscriptExtracted RelationshipUpdated ContactCreated
      FollowupCompleted FollowupOverdue DeadlineReached ReminderDue DigestRequested
      PlannerCompleted AnalyzerCompleted WorkflowRequested NotificationRequested
      ObservationReceived ObservationParsed ExtractionCompleted ProposalCreated
      PolicyValidated ObservationCompleted DatasetChanged RecommendationGenerated
    ].freeze

    def self.default
      new.tap { |registry| DEFAULT_TYPES.each { |type| registry.register(type, versions: [1]) } }
    end

    def initialize
      @versions = {}
      @mutex = Mutex.new
    end

    def register(type, versions: [1])
      name = type.to_s
      raise InvalidEvent, "invalid event type" unless name.match?(Event::TYPE_PATTERN)
      supported = Array(versions).map { |version| Integer(version) }.uniq.sort
      raise InvalidEvent, "event versions must be positive" if supported.empty? || supported.any? { |item| !item.positive? }
      @mutex.synchronize do
        current = @versions[name] || []
        @versions[name] = (current + supported).uniq.sort.freeze
      end
      self
    end

    def validate!(event)
      versions = @mutex.synchronize { @versions[event.type] }
      raise InvalidEvent, "unregistered event type #{event.type}" unless versions
      unless versions.include?(event.version)
        raise UnsupportedEventVersion, "unsupported #{event.type} version #{event.version}"
      end
      true
    end

    def types
      @mutex.synchronize { @versions.keys.sort.freeze }
    end
  end

  class EventFilter
    def initialize(types: nil, sources: nil, correlation_ids: nil, payload: {})
      @types = normalize(types)
      @sources = normalize(sources)
      @correlation_ids = normalize(correlation_ids)
      raise InvalidEvent, "payload filter must be an object" unless payload.is_a?(Hash)
      @payload = payload.transform_keys(&:to_s).freeze
      freeze
    end

    def match?(event)
      return false if @types && !@types.include?(event.type)
      return false if @sources && !@sources.include?(event.source)
      return false if @correlation_ids && !@correlation_ids.include?(event.correlation_id)

      @payload.all? { |key, value| dig(event.payload, key) == value }
    end

    private

    def normalize(values)
      list = Array(values).map(&:to_s).uniq
      list.empty? ? nil : list.freeze
    end

    def dig(value, path)
      path.to_s.split(".").reduce(value) do |current, segment|
        return nil unless current.is_a?(Hash)

        current[segment]
      end
    end
  end

  class EventStore
    RUNTIME = "#{KnowledgeSDK::RUNTIME_PATH}/orchestration".freeze

    def initialize(vault_root:, path: nil)
      @path = path || File.join(File.expand_path(vault_root.to_s), RUNTIME, "events.jsonl")
      @mutex = Mutex.new
      @known_ids = nil
      @last_sequence = nil
    end

    def append(event)
      raise InvalidEvent, "EventStore accepts Event objects only" unless event.is_a?(Event)

      @mutex.synchronize do
        load_index unless @known_ids
        raise InvalidEvent, "event already exists: #{event.id}" if @known_ids.include?(event.id)
        stored = event.with_sequence(@last_sequence + 1)
        AtomicFile.append_jsonl(@path, stored.to_h)
        @known_ids.add(stored.id)
        @last_sequence = stored.sequence
        stored
      end
    end

    def events(filter: nil, after_sequence: nil, limit: nil)
      result = AtomicFile.read_jsonl(@path, error_class: InvalidEvent).map { |item| Event.from_h(item) }
      result.select! { |event| event.sequence > after_sequence.to_i } if after_sequence
      result.select! { |event| filter.match?(event) } if filter
      result = result.first(Integer(limit)) if limit
      result.sort_by(&:sequence).freeze
    end

    def fetch(event_id)
      events.find { |event| event.id == event_id.to_s } ||
        raise(EventNotFound, "event not found: #{event_id}")
    end

    private

    def load_index
      current = events
      @known_ids = Set.new(current.map(&:id))
      @last_sequence = current.last&.sequence || 0
    end
  end

  class DeadLetterStore
    def initialize(vault_root:, path: nil, clock: nil)
      @path = path || File.join(File.expand_path(vault_root.to_s), EventStore::RUNTIME, "dead_letters.jsonl")
      @clock = clock || -> { Time.now }
    end

    def record(event:, subscriber_id:, error:, attempt: 1)
      entry = {
        dead_letter_id: Stable.id("dead-letter", event.id, subscriber_id, attempt),
        timestamp: @clock.call.iso8601(6), event_id: event.id,
        event_type: event.type, subscriber_id: subscriber_id.to_s,
        error_class: error.class.name, error_message: safe_message(error.message),
        attempt: Integer(attempt), replayable: true
      }
      AtomicFile.append_jsonl(@path, entry)
      AgentPlatform::Value.immutable(entry)
    end

    def list
      AtomicFile.read_jsonl(@path, error_class: InvalidEvent).freeze
    end

    private

    def safe_message(value)
      value.to_s.gsub(%r{(?:/[^\s:]+)+}, "[path]")[0, 500]
    end
  end

  class EventBus
    Subscription = Struct.new(:id, :filter, :callable)

    attr_reader :store, :registry, :dead_letters

    def initialize(store:, registry: EventRegistry.default, dead_letters: nil,
                   vault_root: nil, clock: nil, id_generator: nil)
      @store = store
      @registry = registry
      @clock = clock || -> { Time.now }
      @id_generator = id_generator || KnowledgeGraph::IdGenerator.new(clock: @clock)
      @dead_letters = dead_letters || DeadLetterStore.new(vault_root: vault_root || Dir.pwd, clock: @clock)
      @subscriptions = []
      @mutex = Mutex.new
    end

    def subscribe(id:, filter: EventFilter.new, callable: nil, &block)
      handler = callable || block
      raise ArgumentError, "subscriber must respond to call" unless handler.respond_to?(:call)
      subscription = Subscription.new(id.to_s.freeze, filter, handler).freeze
      @mutex.synchronize do
        raise ArgumentError, "duplicate subscriber #{id}" if @subscriptions.any? { |item| item.id == id.to_s }
        @subscriptions << subscription
        @subscriptions.sort_by!(&:id)
      end
      self
    end

    def publish(event = nil, type: nil, source: nil, payload: {}, correlation_id: nil,
                causation_id: nil, trace_id: nil, version: 1, event_id: nil, timestamp: nil)
      candidate = event || build_event(
        type: type, source: source, payload: payload, correlation_id: correlation_id,
        causation_id: causation_id, trace_id: trace_id, version: version,
        event_id: event_id, timestamp: timestamp
      )
      registry.validate!(candidate)
      stored = store.append(candidate)
      dispatch(stored)
      stored
    end

    def replay(event_id, subscriber_ids: nil)
      event = store.fetch(event_id)
      dispatch(event, subscriber_ids: subscriber_ids, replay: true)
      event
    end

    def filter(**criteria)
      store.events(filter: EventFilter.new(**criteria))
    end

    private

    def build_event(type:, source:, payload:, correlation_id:, causation_id:, trace_id:, version:, event_id:, timestamp:)
      id = event_id || @id_generator.generate("event")
      trace = trace_id || @id_generator.generate("trace")
      Event.new(
        id: id, timestamp: timestamp || @clock.call, source: source || "unknown",
        type: type, payload: payload, correlation_id: correlation_id || id,
        causation_id: causation_id, trace_id: trace, version: version
      )
    end

    def dispatch(event, subscriber_ids: nil, replay: false)
      allowed = subscriber_ids && Array(subscriber_ids).map(&:to_s)
      subscribers = @mutex.synchronize { @subscriptions.dup }
      subscribers.each_with_object([]) do |subscription, results|
        next if allowed && !allowed.include?(subscription.id)
        next unless subscription.filter.match?(event)

        results << subscription.callable.call(event, replay: replay)
      rescue StandardError => error
        dead_letters.record(event: event, subscriber_id: subscription.id, error: error)
      end.freeze
    end
  end
end
