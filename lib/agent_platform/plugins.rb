# frozen_string_literal: true

module AgentPlatform
  class PluginRegistrar
    def initialize(registry:, handlers:)
      @registry = registry
      @handlers = handlers
    end

    def register(manifest:, handler:)
      @registry.register(manifest)
      @handlers.register(manifest.capability_id, version: manifest.version, callable: handler)
      self
    end

    def load_manifests(paths, handlers: {})
      ManifestLoader.new.load(paths).each do |manifest|
        callable = handlers[[manifest.capability_id, manifest.version]] || handlers[manifest.capability_id]
        raise HandlerNotRegistered, "plugin handler is required" unless callable

        register(manifest: manifest, handler: callable)
      end
      self
    end
  end
end
