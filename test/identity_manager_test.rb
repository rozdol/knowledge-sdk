# frozen_string_literal: true

require "fileutils"
require_relative "test_helper"

class IdentityManagerTest < Minitest::Test
  PERSON_A = "person_01K1D9VB96W7CS7F4M7K8Q2Z0A"
  PERSON_B = "person_01K1D9VB96W7CS7F4M7K8Q2Z0B"
  PERSON_C = "person_01K1D9VB96W7CS7F4M7K8Q2Z0C"
  ORGANIZATION = "org_01K1D9VB96W7CS7F4M7K8Q2Z0D"
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

  def test_identity_index_finds_strong_duplicate_candidates
    with_identity_vault do |_root, _engine, repository|
      resolver = KnowledgeGraph::IdentityResolver.new(repository: repository)

      candidates = resolver.duplicate_candidates(PERSON_A)

      assert_equal [PERSON_B], candidates.map { |match| match.record.id }
      assert_includes candidates.first.signals, :email
      assert_raises(KnowledgeGraph::IdentityConflict) { resolver.resolve("shared@example.com") }
      assert_equal [PERSON_B], resolver.search("Grace", entity_type: "person").map { |match| match.record.id }
    end
  end

  def test_person_merge_requires_approval_rewrites_edges_and_deduplicates
    with_identity_vault do |root, engine, _repository|
      first = engine.execute(
        KnowledgeGraph::AddRelationship.new(source: PERSON_A, predicate: "knows", target: PERSON_C)
      )
      second = engine.execute(
        KnowledgeGraph::AddRelationship.new(source: PERSON_B, predicate: "knows", target: PERSON_C)
      )
      unapproved = KnowledgeGraph::MergeEntities.new(primary_id: PERSON_A, secondary_id: PERSON_B)

      assert_raises(KnowledgeGraph::ApprovalRequired) { engine.execute(unapproved) }
      assert_equal "active", record(root, PERSON_B).data["record_status"]

      merged = engine.execute(
        KnowledgeGraph::MergeEntities.new(
          primary_id: PERSON_A, secondary_id: PERSON_B, human_approved: true
        )
      )

      primary = record(root, PERSON_A)
      secondary = record(root, PERSON_B)
      assert_equal [PERSON_A, PERSON_B], merged.entity_ids
      assert_includes primary.data["aliases"], "Grace"
      assert_equal "merged", secondary.data["record_status"]
      assert_equal primary.link, secondary.data["merged_into"]
      assert_includes secondary.body, "Human-owned duplicate body."

      first_edge = record(root, first.entity_ids.first)
      second_edge = record(root, second.entity_ids.first)
      assert_equal PERSON_A, first_edge.data["subject_id"]
      assert_equal PERSON_A, second_edge.data["subject_id"]
      assert_equal "asserted", first_edge.data["relationship_status"]
      assert_equal "retracted", second_edge.data["relationship_status"]
      refute_includes File.read(File.join(root, second_edge.relative_path)), "People/Grace"

      repository = repository_for(root)
      assert_equal PERSON_A, repository.resolve(PERSON_B).id
      engine.execute(
        KnowledgeGraph::CreateEntity.new(
          entity_type: "organization",
          attributes: { id: ORGANIZATION, name: "Example", org_kind: "company", domains: ["example.com"] }
        )
      )
      resolver = KnowledgeGraph::IdentityResolver.new(repository: repository_for(root))
      assert_equal PERSON_A, resolver.resolve("shared@example.com").id
      replayed = engine.execute(
        KnowledgeGraph::MergeEntities.new(
          primary_id: PERSON_A, secondary_id: PERSON_B, human_approved: true
        )
      )
      assert replayed.replayed
    end
  end

  def test_split_can_restore_a_merged_stub_but_keeps_rewritten_links_on_survivor
    with_identity_vault do |root, engine, _repository|
      engine.execute(
        KnowledgeGraph::MergeEntities.new(
          primary_id: PERSON_A, secondary_id: PERSON_B, human_approved: true
        )
      )

      split = engine.execute(
        KnowledgeGraph::SplitEntity.new(
          entity_id: PERSON_B,
          attributes: { name: "Grace Restored" },
          human_approved: true
        )
      )

      restored = record(root, PERSON_B)
      assert_equal [PERSON_B], split.entity_ids
      assert_equal "active", restored.data["record_status"]
      refute restored.data.key?("merged_into")
      assert_equal "Grace Restored", restored.data["name"]
      assert_equal PERSON_B, repository_for(root).resolve(PERSON_B).id
    end
  end

  def test_concept_creation_requires_explicit_approval
    with_identity_vault do |root, engine, _repository|
      intent = KnowledgeGraph::CreateEntity.new(
        entity_type: "interest",
        attributes: { name: "Skiing", interest_kind: "sport" }
      )

      assert_raises(KnowledgeGraph::ApprovalRequired) { engine.execute(intent) }
      refute File.exist?(File.join(root, "Concepts/Interests/Skiing.md"))
    end
  end

  private

  def with_identity_vault
    with_vault do |root|
      copy_system_files(root)
      fixed_time = Time.new(2026, 7, 29, 10, 0, 0, "+03:00")
      engine = KnowledgeGraph::Engine.new(
        vault_root: root,
        run_id: RUN_ID,
        clock: -> { fixed_time },
        id_generator: SequenceIdGenerator.new
      )
      create_person(engine, PERSON_A, "Ada", "shared@example.com", true, "# Ada\n")
      create_person(
        engine, PERSON_B, "Grace", "shared@example.com", false,
        "# Grace\n\nHuman-owned duplicate body.\n"
      )
      create_person(engine, PERSON_C, "Katherine", "katherine@example.com", false, "# Katherine\n")
      yield root, engine, repository_for(root)
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

  def create_person(engine, id, name, email, is_self, body)
    attributes = {
      id: id,
      name: name,
      emails: [email],
      tier: "active",
      sensitivity: "private",
      data_origin: "public"
    }
    attributes[:is_self] = true if is_self
    engine.execute(
      KnowledgeGraph::CreateEntity.new(entity_type: "person", attributes: attributes, body: body)
    )
  end

  def repository_for(root)
    registry = KnowledgeGraph::SchemaRegistry.new(vault_root: root)
    KnowledgeGraph::Repository.new(vault_root: root, registry: registry)
  end

  def record(root, entity_id)
    repository_for(root).find(entity_id)
  end
end
