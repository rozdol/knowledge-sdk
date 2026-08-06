# frozen_string_literal: true

module KnowledgeCapture
  class PluginRegistry
    def initialize
      @plugins = {}
    end

    def register(plugin)
      name = plugin.respond_to?(:name) ? plugin.name.to_s.strip : ""
      raise PluginError, "capture plugin name is required" if name.empty?
      unless contribution?(plugin)
        raise PluginError, "capture plugin must contribute an enricher, topic extractor, auto-linker, promotion rule, or recommendation generator"
      end
      existing = @plugins[name]
      if existing && existing.class != plugin.class
        raise PluginError, "capture plugin #{name} conflicts with an existing registration"
      end

      @plugins[name] = plugin
      self
    end

    def all
      @plugins.keys.sort.map { |name| @plugins.fetch(name) }.freeze
    end

    def enrich(attributes)
      all.select { |plugin| plugin.respond_to?(:enrich_capture) }.reduce(attributes) do |value, plugin|
        result = plugin.enrich_capture(immutable(value))
        raise PluginError, "capture enricher #{plugin.name} must return an object" unless result.is_a?(Hash)

        value.merge(result.transform_keys(&:to_s))
      end
    end

    def topics(text)
      all.select { |plugin| plugin.respond_to?(:extract_capture_topics) }.flat_map do |plugin|
        Array(plugin.extract_capture_topics(text.to_s)).map(&:to_s)
      end.reject(&:empty?).uniq.sort.freeze
    end

    def link_candidates(text, context)
      all.select { |plugin| plugin.respond_to?(:capture_link_candidates) }.flat_map do |plugin|
        Array(plugin.capture_link_candidates(text.to_s, immutable(context)))
      end
    end

    def promotion_intents(capture, kind, options)
      all.select { |plugin| plugin.respond_to?(:build_capture_promotion) }.each do |plugin|
        result = plugin.build_capture_promotion(capture, kind.to_s, immutable(options))
        return Array(result) if result
      end
      nil
    end

    def recommendations(capture)
      all.select { |plugin| plugin.respond_to?(:capture_recommendations) }.flat_map do |plugin|
        Array(plugin.capture_recommendations(capture)).map(&:to_s)
      end.reject(&:empty?).uniq.freeze
    end

    private

    def contribution?(plugin)
      %i[
        enrich_capture extract_capture_topics capture_link_candidates
        build_capture_promotion capture_recommendations
      ].any? { |method_name| plugin.respond_to?(method_name) }
    end

    def immutable(value)
      AgentPlatform::Value.immutable(value)
    rescue NameError
      value.freeze
    end
  end
end
