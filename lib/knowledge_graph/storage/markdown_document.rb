# frozen_string_literal: true

require "date"
require "yaml"

module KnowledgeGraph
  class MarkdownDocument
    FRONTMATTER = /\A---\s*\r?\n(.*?)\r?\n---\s*(?:\r?\n|\z)(.*)\z/m

    attr_reader :frontmatter, :body

    def self.parse(content, source: "document")
      match = content.match(FRONTMATTER)
      raise ValidationError, "#{source}: missing or unclosed frontmatter" unless match

      data = YAML.safe_load(match[1], permitted_classes: [Date, Time], aliases: false)
      raise ValidationError, "#{source}: frontmatter must be a mapping" unless data.is_a?(Hash)

      new(frontmatter: data.transform_keys(&:to_s), body: match[2])
    rescue Psych::SyntaxError => error
      raise ValidationError, "#{source}: YAML error: #{error.message.lines.first.strip}"
    end

    def initialize(frontmatter:, body: "")
      @frontmatter = frontmatter.transform_keys(&:to_s).freeze
      @body = body.to_s.dup.freeze
      freeze
    end
  end
end
