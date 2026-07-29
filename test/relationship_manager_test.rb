# frozen_string_literal: true

require "fileutils"
require_relative "test_helper"

class RelationshipManagerTest < Minitest::Test
  PERSON_A = "person_01K1D9VB96W7CS7F4M7K8Q2Z0A"
  PERSON_B = "person_01K1D9VB96W7CS7F4M7K8Q2Z0B"
  RELATIONSHIP_A = "relationship_01K1DEG5AB7ZQ9H4N2VCR8Q4ZA"
  RELATIONSHIP_B = "relationship_01K1DEG5AB7ZQ9H4N2VCR8Q4ZB"
  RUN_ID = "run_01KYQADDKGCXF0H38JFT5EN0CV"

  class SequenceIdGenerator
    def initialize
      @relationship_ids = [RELATIONSHIP_A, RELATIONSHIP_B]
    end

    def generate(prefix)
      return @relationship_ids.shift if prefix == "relationship"

      "#{prefix}_01K1DCC8Q6V4R5T7S2NXB8K4QW"
    end
  end

  def test_add_normalizes_symmetric_endpoints_and_is_idempotent
    with_relationship_vault do |root, engine|
      intent = KnowledgeGraph::AddRelationship.new(source: PERSON_B, predicate: "knows", target: PERSON_A)

      first = engine.execute(intent)
      second = engine.execute(intent)

      document = read_record(root, first.value.fetch(:relative_path))
      assert_equal PERSON_A, document.frontmatter["subject_id"]
      assert_equal PERSON_B, document.frontmatter["object_id"]
      assert_equal "[[People/Ada|Ada]]", document.frontmatter["subject"]
      refute first.replayed
      assert second.replayed
      assert_equal [RELATIONSHIP_A], second.entity_ids
      assert_equal 1, Dir.glob(File.join(root, "Relationships/knows/*.md")).length
    end
  end

  def test_rejects_invalid_endpoint_types_without_writing
    with_relationship_vault do |root, engine|
      intent = KnowledgeGraph::AddRelationship.new(source: PERSON_A, predicate: "works_for", target: PERSON_B)

      assert_raises(KnowledgeGraph::RelationshipConflict) { engine.execute(intent) }

      assert_empty Dir.glob(File.join(root, "Relationships/works_for/*.md"))
    end
  end

  def test_remove_retracts_and_replace_is_atomic
    with_relationship_vault do |root, engine|
      added = engine.execute(
        KnowledgeGraph::AddRelationship.new(source: PERSON_A, predicate: "knows", target: PERSON_B)
      )
      replaced = engine.execute(
        KnowledgeGraph::ReplaceRelationship.new(
          relationship_id: added.entity_ids.first,
          source: PERSON_A,
          predicate: "friend_of",
          target: PERSON_B,
          attributes: { closeness: "close" }
        )
      )

      old_document = read_record(root, added.value.fetch(:relative_path))
      new_document = read_record(root, replaced.value.fetch(:relative_path))
      assert_equal "retracted", old_document.frontmatter["relationship_status"]
      assert_equal "asserted", new_document.frontmatter["relationship_status"]
      assert_equal "friend_of", new_document.frontmatter["predicate"]
      assert_equal "close", new_document.frontmatter["closeness"]
      assert_equal [RELATIONSHIP_A, RELATIONSHIP_B], replaced.entity_ids

      removed = engine.execute(KnowledgeGraph::RemoveRelationship.new(relationship_id: RELATIONSHIP_B))
      replayed = engine.execute(KnowledgeGraph::RemoveRelationship.new(relationship_id: RELATIONSHIP_B))
      assert_equal "retracted", read_record(root, removed.value.fetch(:relative_path)).frontmatter["relationship_status"]
      assert replayed.replayed
    end
  end

  def test_registry_exposes_inverse_without_creating_duplicate_edge
    with_relationship_vault do |root, engine|
      registry = KnowledgeGraph::RelationshipRegistry.new(vault_root: root)
      assert_equal "employs", registry.inverse_for("works_for")

      engine.execute(KnowledgeGraph::AddRelationship.new(source: PERSON_A, predicate: "knows", target: PERSON_B))
      assert_equal 1, Dir.glob(File.join(root, "Relationships/**/*.md")).length
    end
  end

  private

  def with_relationship_vault
    with_vault do |root|
      copy_system_files(root)
      fixed_time = Time.new(2026, 7, 29, 10, 0, 0, "+03:00")
      engine = KnowledgeGraph::Engine.new(
        vault_root: root,
        run_id: RUN_ID,
        clock: -> { fixed_time },
        id_generator: SequenceIdGenerator.new
      )
      create_person(engine, PERSON_A, "Ada", true)
      create_person(engine, PERSON_B, "Grace", false)
      yield root, engine
    end
  end

  def copy_system_files(root)
    source_root = File.expand_path("../../..", __dir__)
    FileUtils.mkdir_p(File.join(root, "_System"))
    FileUtils.cp_r(File.join(source_root, "_System/Schema"), File.join(root, "_System/Schema"))
    FileUtils.cp_r(
      File.join(source_root, "_System/Relationship Types"),
      File.join(root, "_System/Relationship Types")
    )
    FileUtils.mkdir_p(File.join(root, "_System/Tools"))
    FileUtils.cp(
      File.join(source_root, "_System/Tools/validate_vault.rb"),
      File.join(root, "_System/Tools/validate_vault.rb")
    )
  end

  def create_person(engine, id, name, is_self)
    attributes = {
      id: id, name: name, tier: "active", sensitivity: "private", data_origin: "public"
    }
    attributes[:is_self] = true if is_self
    engine.execute(KnowledgeGraph::CreateEntity.new(entity_type: "person", attributes: attributes))
  end

  def read_record(root, relative_path)
    KnowledgeGraph::MarkdownDocument.parse(File.read(File.join(root, relative_path)))
  end
end
