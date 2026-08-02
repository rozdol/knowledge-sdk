# frozen_string_literal: true

module KnowledgeSDK
  class IntentClassification
    attr_reader :intent, :confidence, :route, :reason, :slots

    def initialize(intent:, confidence:, route:, reason:, slots: {})
      @intent = required(intent, "intent")
      @route = required(route, "route")
      @reason = required(reason, "reason")
      @confidence = Float(confidence)
      unless @confidence.between?(0.0, 1.0)
        raise ArgumentError, "classification confidence must be between 0 and 1"
      end
      raise ArgumentError, "classification slots must be an object" unless slots.is_a?(Hash)

      @slots = immutable(slots)
      freeze
    rescue ArgumentError, TypeError => error
      raise ArgumentError, error.message
    end

    def to_h
      {
        "intent" => intent, "confidence" => confidence,
        "route" => route, "reason" => reason, "slots" => slots
      }
    end

    private

    def required(value, field)
      string = value.to_s.strip
      raise ArgumentError, "classification #{field} is required" if string.empty?

      string.freeze
    end

    def immutable(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, item), result|
          result[key.to_s.freeze] = immutable(item)
        end.freeze
      when Array then value.map { |item| immutable(item) }.freeze
      when String then value.dup.freeze
      else value.frozen? ? value : value.dup.freeze
      end
    rescue TypeError
      value.freeze
    end
  end

  class IntentClassifier
    ROUTE_PRIORITY = %w[dataset analyze observe search plan proposal].freeze
    Entry = Struct.new(:name, :route, :matcher, keyword_init: true)

    def initialize
      @entries = {}
    end

    # Trusted SDK plugins register deterministic classifiers here. Registering the
    # same name replaces that plugin, which keeps application boot idempotent.
    def register(name:, route:, matcher: nil, &block)
      callable = matcher || block
      route_name = route.to_s
      raise ArgumentError, "classifier matcher must respond to call" unless callable&.respond_to?(:call)
      unless ROUTE_PRIORITY.include?(route_name)
        raise ArgumentError, "unsupported classifier route #{route_name.inspect}"
      end

      key = name.to_s.strip
      raise ArgumentError, "classifier name is required" if key.empty?
      existing = @entries[key]
      if existing && existing.route != route_name
        raise ArgumentError, "classifier #{key} is already registered for #{existing.route}"
      end

      @entries[key] = Entry.new(name: key.freeze, route: route_name.freeze, matcher: callable).freeze
      self
    end

    def classify(text, context = {})
      source = text.to_s.strip
      raise ArgumentError, "classification text is empty" if source.empty?
      raise ArgumentError, "classification context must be an object" unless context.is_a?(Hash)

      ROUTE_PRIORITY.each do |route|
        matches = []
        entries_for(route).each do |entry|
          result = entry.matcher.call(source, context)
          next unless result

          matches << normalize(result, entry)
        end
        return matches.max_by(&:confidence) unless matches.empty?
      end
      nil
    end

    def registrations
      ROUTE_PRIORITY.each_with_object([]) do |route, result|
        entries_for(route).each { |entry| result << { "name" => entry.name, "route" => entry.route } }
      end.freeze
    end

    private

    def entries_for(route)
      @entries.values.select { |entry| entry.route == route }.sort_by(&:name)
    end

    def normalize(result, entry)
      return result if result.is_a?(IntentClassification)
      raise ArgumentError, "classifier #{entry.name} returned an invalid result" unless result.is_a?(Hash)

      data = result.each_with_object({}) { |(key, value), copy| copy[key.to_s] = value }
      IntentClassification.new(
        intent: data.fetch("intent"), confidence: data.fetch("confidence"),
        route: entry.route, reason: data.fetch("reason"), slots: data.fetch("slots", {})
      )
    rescue KeyError => error
      raise ArgumentError, "classifier #{entry.name} result is missing #{error.key}"
    end
  end
end
