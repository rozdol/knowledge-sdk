# frozen_string_literal: true

require "fileutils"
require_relative "test_helper"

class StorageIntegrationTest < Minitest::Test
  FIXED_ID = "person_01K1D9VB96W7CS7F4M7K8Q2Z0A"
  RUN_ID = "run_01KYQADDKGCXF0H38JFT5EN0CV"

  class FixedIdGenerator
    def generate(prefix)
      prefix == "person" ? FIXED_ID : "#{prefix}_01K1DCC8Q6V4R5T7S2NXB8K4QW"
    end
  end

  def test_create_update_and_rename_use_writer_and_external_validator
    with_schema_vault do |root|
      engine = build_engine(root)
      create = KnowledgeGraph::CreateEntity.new(
        entity_type: "person",
        attributes: {
          name: "Ada Lovelace", tier: "active", sensitivity: "private",
          data_origin: "public", is_self: true, custom_scalar: "preserved"
        },
        body: "# Ada Lovelace\n\nHuman-owned biography.\n"
      )

      created = engine.execute(create)
      engine.execute(KnowledgeGraph::UpdateEntity.new(entity_id: FIXED_ID, changes: { pronouns: "she/her" }))
      renamed = engine.execute(KnowledgeGraph::RenameEntity.new(entity_id: FIXED_ID, new_name: "Ada King"))

      refute File.exist?(File.join(root, "People/Ada Lovelace.md"))
      path = File.join(root, renamed.value.fetch(:relative_path))
      document = KnowledgeGraph::MarkdownDocument.parse(File.read(path))
      assert_equal "Ada King", document.frontmatter["name"]
      assert_equal ["Ada Lovelace"], document.frontmatter["aliases"]
      assert_equal "she/her", document.frontmatter["pronouns"]
      assert_equal "preserved", document.frontmatter["custom_scalar"]
      assert_equal "# Ada Lovelace\n\nHuman-owned biography.\n", document.body
      assert_equal [FIXED_ID], created.entity_ids
    end
  end

  def test_rename_supports_utf8_names_when_rewriting_backlinks
    with_schema_vault do |root|
      FileUtils.mkdir_p(File.join(root, "Notes"))
      File.write(File.join(root, "Notes/Unicode.md"), "# Заметка\n")
      engine = build_engine(root)
      engine.execute(KnowledgeGraph::CreateEntity.new(
        entity_type: "person",
        attributes: {
          name: "Мария Титова", tier: "active", sensitivity: "private",
          data_origin: "third_party", is_self: true
        }
      ))

      renamed = engine.execute(
        KnowledgeGraph::RenameEntity.new(entity_id: FIXED_ID, new_name: "Мария Курлычева")
      )

      assert_equal "People/Мария Курлычева.md", renamed.value.fetch(:relative_path)
      refute File.exist?(File.join(root, "People/Мария Титова.md"))
    end
  end

  def test_invalid_candidate_is_never_committed
    with_schema_vault do |root|
      engine = build_engine(root)
      intent = KnowledgeGraph::CreateEntity.new(
        entity_type: "person",
        attributes: { name: "Invalid Person", sensitivity: "private", data_origin: "public", is_self: true }
      )

      error = assert_raises(KnowledgeGraph::ValidationError) { engine.execute(intent) }

      assert_includes error.message, "missing required field tier"
      refute File.exist?(File.join(root, "People/Invalid Person.md"))
    end
  end

  private

  def with_schema_vault
    super { |root| yield root }
  end

  def build_engine(root)
    fixed_time = Time.new(2026, 7, 29, 10, 0, 0, "+03:00")
    KnowledgeGraph::Engine.new(
      vault_root: root,
      run_id: RUN_ID,
      clock: -> { fixed_time },
      id_generator: FixedIdGenerator.new
    )
  end
end
