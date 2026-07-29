# frozen_string_literal: true

module KnowledgeGraph
  class RelationshipDefinition
    attr_reader :predicate, :subject_types, :object_types, :inverse, :allowed_fields, :required_fields

    def initialize(data)
      @predicate = data.fetch("predicate").to_s.freeze
      @subject_types = Array(data.fetch("subject_types")).map(&:to_s).freeze
      @object_types = Array(data.fetch("object_types")).map(&:to_s).freeze
      @inverse = data.fetch("inverse").to_s.freeze
      @allowed_fields = Array(data.fetch("allowed_fields")).map(&:to_s).freeze
      @required_fields = Array(data.fetch("required_fields")).map(&:to_s).freeze
      @symmetric = !!data.fetch("symmetric")
      freeze
    end

    def symmetric?
      @symmetric
    end
  end

  class RelationshipRegistry
    def initialize(vault_root:)
      @vault_root = Pathname.new(vault_root)
      @definitions = nil
    end

    def fetch(predicate)
      definitions.fetch(predicate.to_s) do
        raise RelationshipConflict, "unregistered predicate #{predicate.inspect}"
      end
    end

    def inverse_for(predicate)
      fetch(predicate).inverse
    end

    def predicates
      definitions.keys.freeze
    end

    private

    def definitions
      @definitions ||= load_definitions.freeze
    end

    def load_definitions
      pattern = @vault_root.join("_System/Relationship Types/*.md").to_s
      Dir.glob(pattern).sort.each_with_object({}) do |filename, result|
        document = MarkdownDocument.parse(File.read(filename), source: filename)
        definition = RelationshipDefinition.new(document.frontmatter)
        if result.key?(definition.predicate)
          raise SchemaError, "duplicate relationship predicate #{definition.predicate}"
        end
        result[definition.predicate] = definition
      end
    end
  end
end
