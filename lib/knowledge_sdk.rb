# frozen_string_literal: true

require "pathname"

require_relative "knowledge_sdk/version"

module KnowledgeSDK
  class Error < StandardError; end
  class ConfigurationError < Error; end
  class VaultNotFound < Error; end
  class PluginError < Error; end
  class MigrationError < Error; end

  RUNTIME_PATH = ".knowledge/runtime".freeze
  DATASET_PATH = ".knowledge/datasets.sqlite3".freeze

  class << self
    attr_writer :config_path
    attr_writer :dataset_path_override

    def root
      @root ||= Pathname.new(File.expand_path("..", __dir__)).freeze
    end

    def config_path
      @config_path || ENV["KG_CONFIG"] || File.expand_path("~/.knowledge-sdk/config.yml")
    end

    def configuration
      Configuration.new(path: config_path)
    end

    def registry
      VaultRegistry.new(configuration: configuration)
    end

    def attach(path, **options)
      registry.attach(path, **options)
    end

    def engine(vault:, **options)
      require_relative "knowledge_graph" unless defined?(KnowledgeGraph::Engine)
      KnowledgeGraph::Engine.new(**options.merge(vault_root: vault))
    end

    def profile_for(vault_root)
      record = registry.find(File.expand_path(vault_root.to_s))
      (record && record["profile"]) || PluginRegistry.new.detect(vault_root)
    end

    def validator_path(vault_root)
      profile = profile_for(vault_root)
      return root.join("validators/generic/validate_vault.rb") unless profile

      PluginRegistry.new.validator_path(profile)
    end

    def dataset_path(vault_root)
      configured = @dataset_path_override || configuration.dataset_db
      return Pathname.new(vault_root).expand_path.join(DATASET_PATH) if configured.to_s.strip.empty?

      candidate = Pathname.new(configured.to_s)
      return candidate.expand_path if candidate.absolute? || configured.to_s.start_with?("~")

      Pathname.new(vault_root).expand_path.join(candidate).expand_path
    end
  end
end

require_relative "knowledge_sdk/configuration"
require_relative "knowledge_sdk/plugin_registry"
require_relative "knowledge_sdk/vault_registry"
require_relative "knowledge_sdk/vault_locator"
require_relative "knowledge_sdk/migration"
