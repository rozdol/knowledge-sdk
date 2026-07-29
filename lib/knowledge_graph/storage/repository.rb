# frozen_string_literal: true

require "pathname"

module KnowledgeGraph
  class Record
    attr_reader :relative_path, :document

    def initialize(relative_path:, document:)
      @relative_path = relative_path.to_s.freeze
      @document = document
      freeze
    end

    def data
      document.frontmatter
    end

    def body
      document.body
    end

    def id
      data.fetch("id")
    end

    def type
      data.fetch("type")
    end

    def link(alias_text = nil)
      target = relative_path.sub(/\.md\z/, "")
      label = alias_text || data["name"] || id
      "[[#{target}|#{label}]]"
    end
  end

  class Repository
    EXCLUDED_PREFIXES = [
      ".git/", ".obsidian/", "_System/Templates/", "_System/Schema/", "_System/Relationship Types/"
    ].freeze

    attr_reader :vault_root

    def initialize(vault_root:, registry:)
      @vault_root = Pathname.new(vault_root)
      @registry = registry
      @records = nil
    end

    def find(entity_id)
      records.fetch(entity_id.to_s) { raise EntityNotFound, "entity not found: #{entity_id}" }
    end

    def resolve(entity_id)
      record = find(entity_id)
      visited = {}
      while record.data["record_status"] == "merged"
        raise IdentityConflict, "merged redirect cycle at #{record.id}" if visited[record.id]

        visited[record.id] = true
        target = wikilink_target(record.data["merged_into"])
        raise IdentityConflict, "merged record #{record.id} has an invalid redirect" unless target

        record = find_by_path("#{target.sub(/\.md\z/, '')}.md")
        raise EntityNotFound, "merged redirect target not found: #{target}" unless record
      end
      record
    end

    def find_by_path(relative_path)
      records.values.find { |record| record.relative_path == relative_path.to_s }
    end

    def each_record(&block)
      records.values.each(&block)
    end

    def markdown_paths
      Dir.glob(@vault_root.join("**/*.md").to_s).sort.map do |filename|
        Pathname.new(filename).relative_path_from(@vault_root).to_s
      end
    end

    private

    def wikilink_target(value)
      match = value.to_s.match(/\A\[\[([^\]|#]+)(?:#[^\]|]+)?(?:\|[^\]]+)?\]\]\z/)
      match && match[1]
    end

    def records
      @records ||= load_records.freeze
    end

    def load_records
      markdown_paths.each_with_object({}) do |relative, result|
        next if EXCLUDED_PREFIXES.any? { |prefix| relative.start_with?(prefix) }

        content = @vault_root.join(relative).read
        next unless content.start_with?("---\n", "---\r\n")

        document = MarkdownDocument.parse(content, source: relative)
        type = document.frontmatter["type"]
        next unless type && @registry.key?(type)

        record = Record.new(relative_path: relative, document: document)
        raise EntityConflict, "duplicate entity ID #{record.id}" if result.key?(record.id)

        result[record.id] = record
      end
    end
  end
end
