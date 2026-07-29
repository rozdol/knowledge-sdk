# frozen_string_literal: true

require "pathname"

module KnowledgeGraph
  class EntitySchema
    attr_reader :key, :id_prefix, :folder_prefixes, :required_tags, :required_fields

    def initialize(data)
      @key = data.fetch("schema_key").to_s.freeze
      @id_prefix = data.fetch("id_prefix").to_s.freeze
      @folder_prefixes = Array(data.fetch("folder_prefixes")).map(&:to_s).freeze
      @required_tags = Array(data.fetch("required_tags")).map(&:to_s).freeze
      @required_fields = Array(data.fetch("required_fields")).map(&:to_s).freeze
      @name_required = !!data.fetch("name_required")
      @id_filename = !!data.fetch("id_filename")
      freeze
    end

    def name_required?
      @name_required
    end

    def id_filename?
      @id_filename
    end
  end

  class SchemaRegistry
    attr_reader :vault_root

    def initialize(vault_root:)
      @vault_root = Pathname.new(vault_root)
      @schemas = nil
    end

    def fetch(key)
      schemas.fetch(key.to_s) { raise SchemaError, "unknown entity type #{key.inspect}" }
    end

    def key?(key)
      schemas.key?(key.to_s)
    end

    def keys
      schemas.keys.freeze
    end

    private

    def schemas
      @schemas ||= load_schemas.freeze
    end

    def load_schemas
      pattern = @vault_root.join("_System/Schema/Entity Types/*.md").to_s
      Dir.glob(pattern).sort.each_with_object({}) do |filename, result|
        document = MarkdownDocument.parse(File.read(filename), source: filename)
        schema = EntitySchema.new(document.frontmatter)
        raise SchemaError, "duplicate schema #{schema.key}" if result.key?(schema.key)

        result[schema.key] = schema
      end
    end
  end
end
