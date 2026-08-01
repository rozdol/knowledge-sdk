# frozen_string_literal: true

require "fileutils"
require "pathname"
require "tempfile"
require "yaml"

module KnowledgeSDK
  class Configuration
    FORMAT_VERSION = 1

    attr_reader :path

    def initialize(path: KnowledgeSDK.config_path)
      @path = Pathname.new(path).expand_path
      @data = load_data
    end

    def active_vault
      @data["active_vault"]
    end

    def active_vault=(value)
      @data["active_vault"] = value
    end

    def vaults
      @data["vaults"] ||= {}
    end

    def plugins
      Array(@data["plugins"])
    end

    def dataset_db
      @data["dataset_db"]
    end

    def to_h
      deep_copy(@data)
    end

    def save!
      FileUtils.mkdir_p(path.dirname)
      Tempfile.create([".config", ".yml"], path.dirname.to_s) do |file|
        file.write(YAML.dump(@data))
        file.flush
        file.fsync
        file.close
        File.rename(file.path, path.to_s)
      end
      path
    end

    private

    def load_data
      return defaults unless path.file?

      parsed = YAML.safe_load(path.read, permitted_classes: [Time], aliases: false)
      raise ConfigurationError, "configuration must be a YAML mapping: #{path}" unless parsed.is_a?(Hash)

      data = stringify_keys(parsed)
      version = Integer(data.fetch("version", FORMAT_VERSION))
      raise ConfigurationError, "unsupported configuration version #{version}" unless version == FORMAT_VERSION

      defaults.merge(data).tap { |value| value["vaults"] ||= {} }
    rescue Psych::SyntaxError, ArgumentError => error
      raise ConfigurationError, "invalid configuration #{path}: #{error.message}"
    end

    def defaults
      { "version" => FORMAT_VERSION, "active_vault" => nil, "vaults" => {}, "plugins" => [] }
    end

    def stringify_keys(value)
      case value
      when Hash
        value.each_with_object({}) { |(key, item), result| result[key.to_s] = stringify_keys(item) }
      when Array then value.map { |item| stringify_keys(item) }
      else value
      end
    end

    def deep_copy(value)
      Marshal.load(Marshal.dump(value))
    end
  end
end
