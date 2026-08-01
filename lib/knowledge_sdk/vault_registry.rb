# frozen_string_literal: true

require "digest"
require "pathname"
require "time"

module KnowledgeSDK
  class VaultRegistry
    attr_reader :configuration

    def initialize(configuration: Configuration.new)
      @configuration = configuration
    end

    def attach(path, name: nil, profile: nil)
      root = directory!(path)
      existing = find(root.to_s)
      id = existing ? existing.fetch("id") : vault_id(root)
      detected_profile = profile || PluginRegistry.new.detect(root)
      record = {
        "id" => id,
        "name" => present(name) || (existing && existing["name"]) || root.basename.to_s,
        "path" => root.to_s,
        "profile" => detected_profile,
        "attached_at" => (existing && existing["attached_at"]) || Time.now.iso8601
      }.reject { |_key, value| value.nil? }
      configuration.vaults[id] = record
      configuration.active_vault ||= id
      configuration.save!
      record.freeze
    end

    def detach(reference)
      record = fetch(reference)
      configuration.vaults.delete(record.fetch("id"))
      if configuration.active_vault == record.fetch("id")
        configuration.active_vault = configuration.vaults.keys.sort.first
      end
      configuration.save!
      record
    end

    def use(reference)
      record = fetch(reference)
      configuration.active_vault = record.fetch("id")
      configuration.save!
      record
    end

    def current
      id = configuration.active_vault
      id && configuration.vaults[id]
    end

    def all
      configuration.vaults.values.sort_by { |record| [record.fetch("name").downcase, record.fetch("path")] }
    end

    def fetch(reference)
      find(reference) || raise(VaultNotFound, "vault is not attached: #{reference}")
    end

    def find(reference)
      return nil if reference.nil?

      value = reference.to_s
      direct = configuration.vaults[value]
      return direct if direct

      expanded_path = Pathname.new(value).expand_path
      expanded = expanded_path.exist? ? expanded_path.realpath.to_s : expanded_path.to_s
      configuration.vaults.values.find do |record|
        record.fetch("path") == expanded || record.fetch("name").casecmp(value).zero?
      end
    end

    private

    def directory!(path)
      root = Pathname.new(path.to_s).expand_path
      raise VaultNotFound, "vault directory does not exist: #{root}" unless root.directory?

      root.realpath
    end

    def vault_id(root)
      "vault_#{Digest::SHA256.hexdigest(root.to_s)[0, 16]}"
    end

    def present(value)
      text = value.to_s.strip
      text.empty? ? nil : text
    end
  end
end
