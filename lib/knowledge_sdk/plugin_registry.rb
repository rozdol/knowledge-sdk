# frozen_string_literal: true

require "fileutils"
require "pathname"
require "yaml"

module KnowledgeSDK
  class PluginRegistry
    def initialize(root: KnowledgeSDK.root.join("plugins"))
      @root = Pathname.new(root)
    end

    def all
      Dir.glob(@root.join("*/plugin.yml").to_s).sort.map { |path| load_manifest(path) }.freeze
    end

    def fetch(name)
      all.find { |plugin| plugin.fetch("name") == name.to_s } ||
        raise(PluginError, "unknown plugin #{name.inspect}")
    end

    def detect(vault_root)
      root = Pathname.new(vault_root)
      return "personal-crm" if root.join("_System/Schema/Entity Types").directory? &&
                               root.join("_System/Relationship Types").directory?

      nil
    end

    def install(name, vault_root)
      plugin = fetch(name)
      root = Pathname.new(vault_root)
      installed = []
      copies = []
      {
        "schemas" => "_System/Schema/Entity Types",
        "relationship_types" => "_System/Relationship Types",
        "templates" => "_System/Templates",
        "views" => "_System/Views"
      }.each do |source_key, destination|
        source = Pathname.new(plugin.fetch("root")).join(plugin.fetch(source_key))
        next unless source.directory?

        target = root.join(destination)
        Dir.glob(source.join("*").to_s).sort.each do |entry|
          destination_path = target.join(File.basename(entry))
          if destination_path.file? && source_key == "schemas" &&
             Array(plugin["shared_schemas"]).include?(File.basename(entry)) &&
             File.binread(entry) == destination_path.binread
            next
          end
          raise PluginError, "plugin install would replace #{destination_path}" if destination_path.exist?
          copies << [entry, destination_path]
        end
      end
      copies.each do |entry, destination_path|
        FileUtils.mkdir_p(destination_path.dirname)
        FileUtils.copy_entry(entry, destination_path)
        installed << destination_path.relative_path_from(root).to_s
      end
      installed.freeze
    end

    def validator_path(profile)
      plugin = fetch(profile)
      KnowledgeSDK.root.join(plugin.fetch("validator")).expand_path
    end

    private

    def load_manifest(path)
      data = YAML.safe_load(File.read(path), aliases: false)
      raise PluginError, "plugin manifest must be a mapping: #{path}" unless data.is_a?(Hash)

      data.transform_keys(&:to_s).merge("root" => File.dirname(path)).freeze
    rescue Psych::SyntaxError => error
      raise PluginError, "invalid plugin manifest #{path}: #{error.message}"
    end
  end
end
