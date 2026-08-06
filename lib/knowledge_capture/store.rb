# frozen_string_literal: true

require "pathname"

module KnowledgeCapture
  class Store
    ROOT = "Captures".freeze

    attr_reader :vault_root

    def initialize(vault_root:)
      @vault_root = Pathname.new(vault_root).expand_path
    end

    def all
      Dir.glob(vault_root.join(ROOT, "**/*.md").to_s).sort.map do |filename|
        path = Pathname.new(filename)
        relative = path.relative_path_from(vault_root).to_s
        document = KnowledgeGraph::MarkdownDocument.parse(path.read, source: relative)
        next unless document.frontmatter["type"] == "capture"

        Capture.new(data: document.frontmatter, body: document.body, relative_path: relative)
      end.compact.sort_by { |capture| [capture.captured_at, capture.id] }.freeze
    end

    def find(reference)
      query = reference.to_s.strip
      raise CaptureNotFound, "capture reference is required" if query.empty?

      exact = all.find { |capture| capture.id == query }
      return exact if exact

      normalized = normalize(query)
      matches = all.select do |capture|
        normalize(capture.title) == normalized || normalize(capture.title).include?(normalized)
      end
      raise CaptureNotFound, "capture not found: #{reference}" if matches.empty?
      if matches.length > 1
        raise AmbiguousCapture, "multiple captures match #{reference.inspect}; use a more specific title or request IDs"
      end

      matches.first
    end

    def latest(status: nil)
      selected = status ? all.select { |capture| capture.status == status.to_s } : all
      selected.max_by { |capture| [capture.captured_at, capture.id] }
    end

    def path_for(capture_id)
      vault_root.join(ROOT, "#{capture_id}.md")
    end

    private

    def normalize(value)
      value.to_s.encode(Encoding::UTF_8).unicode_normalize(:nfc).downcase.tr("ё", "е").strip
    end
  end
end
