# frozen_string_literal: true

require "pathname"

module KnowledgeSDK
  class VaultLocator
    Resolution = Struct.new(:path, :source, :record, keyword_init: true)

    def initialize(registry: VaultRegistry.new, cwd: Dir.pwd, environment: ENV)
      @registry = registry
      @cwd = Pathname.new(cwd).expand_path
      @environment = environment
    end

    def resolve(explicit: nil)
      return resolution(explicit, "cli") if present(explicit)
      return resolution(@environment["KG_VAULT"], "environment") if present(@environment["KG_VAULT"])

      discovered = discover_upward
      return resolution(discovered, "directory") if discovered

      current = @registry.current
      return resolution(current.fetch("path"), "configured", current) if current

      raise VaultNotFound,
            "no Obsidian Vault found; use --vault PATH, set KG_VAULT, or run kg attach PATH"
    end

    private

    def discover_upward
      @cwd.ascend do |candidate|
        registered = @registry.find(candidate.to_s)
        return candidate if registered
        return candidate if candidate.join(".obsidian").directory?
      end
      nil
    end

    def resolution(path, source, record = nil)
      root = Pathname.new(path.to_s).expand_path
      raise VaultNotFound, "vault directory does not exist: #{root}" unless root.directory?

      record ||= @registry.find(root.to_s)
      Resolution.new(path: root.realpath.freeze, source: source.freeze, record: record).freeze
    end

    def present(value)
      !value.to_s.strip.empty?
    end
  end
end
