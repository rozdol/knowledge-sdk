# frozen_string_literal: true

require "digest"
require "thread"

module AgentPlatform
  class CapabilityReference
    attr_reader :manifest, :invocation_token

    def initialize(manifest, invocation_token)
      @manifest = manifest
      @invocation_token = invocation_token.to_s.freeze
      freeze
    end

    def to_h
      manifest.public_contract.merge("invocation_token" => invocation_token)
    end
  end

  class CapabilityRegistry
    def initialize(manifests = [])
      @by_id = {}
      @by_token = {}
      @mutex = Mutex.new
      Array(manifests).each { |manifest| register(manifest) }
    end

    def register(manifest)
      raise InvalidManifest, "expected CapabilityManifest" unless manifest.is_a?(CapabilityManifest)

      @mutex.synchronize do
        versions = (@by_id[manifest.capability_id] ||= {})
        if versions.key?(manifest.version)
          raise InvalidManifest, "duplicate capability #{manifest.capability_id}@#{manifest.version}"
        end
        token = token_for(manifest)
        raise InvalidManifest, "capability token collision" if @by_token.key?(token)

        versions[manifest.version] = manifest
        @by_token[token] = manifest
      end
      self
    end

    def fetch(capability_id, version: nil)
      versions = @mutex.synchronize { @by_id[capability_id.to_s]&.dup }
      raise CapabilityNotFound, "unknown capability" unless versions

      return versions.fetch(version.to_s) { raise CapabilityNotFound, "unknown capability version" } if version

      versions.values.max_by { |manifest| ManifestCompatibility.version_parts(manifest.version) }
    end

    def fetch_token(token)
      @mutex.synchronize do
        @by_token.fetch(token.to_s) { raise CapabilityNotFound, "unknown or stale capability token" }
      end
    end

    def reference(manifest)
      CapabilityReference.new(manifest, token_for(manifest))
    end

    def reference_for(capability_id, version: nil)
      reference(fetch(capability_id, version: version))
    end

    def list
      manifests = @mutex.synchronize { @by_id.values.flat_map(&:values) }
      manifests.sort_by do |manifest|
        [manifest.capability_id, ManifestCompatibility.version_parts(manifest.version)]
      end.freeze
    end

    def size
      list.length
    end

    private

    def token_for(manifest)
      "cap_#{Digest::SHA256.hexdigest([manifest.capability_id, manifest.version, manifest.digest].join(':'))[0, 48]}"
    end
  end

  class HandlerRegistry
    def initialize
      @handlers = {}
      @mutex = Mutex.new
    end

    def register(capability_id, version: "1.0.0", callable: nil, &block)
      handler = callable || block
      raise ArgumentError, "handler must respond to call" unless handler.respond_to?(:call)

      key = [capability_id.to_s, version.to_s]
      @mutex.synchronize do
        raise ArgumentError, "handler already registered" if @handlers.key?(key)

        @handlers[key] = handler
      end
      self
    end

    def fetch(manifest)
      @mutex.synchronize do
        @handlers.fetch([manifest.capability_id, manifest.version]) do
          raise HandlerNotRegistered, "capability implementation is unavailable"
        end
      end
    end

    def registered?(manifest)
      @mutex.synchronize { @handlers.key?([manifest.capability_id, manifest.version]) }
    end
  end
end
