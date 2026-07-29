# frozen_string_literal: true

require_relative "test_helper"

class TransactionTest < Minitest::Test
  def test_commits_multiple_writes_and_deletes
    with_vault do |root|
      File.write(File.join(root, "old.txt"), "old")
      transaction = KnowledgeGraph::Transaction.new(vault_root: root)
      transaction.write("one.txt", "one")
      transaction.write("nested/two.txt", "two")
      transaction.delete("old.txt")

      transaction.commit

      assert_equal "one", File.read(File.join(root, "one.txt"))
      assert_equal "two", File.read(File.join(root, "nested/two.txt"))
      refute File.exist?(File.join(root, "old.txt"))
      assert_equal :committed, transaction.state
    end
  end

  def test_restores_all_files_when_commit_fails_midway
    with_vault do |root|
      File.write(File.join(root, "one.txt"), "original one")
      File.write(File.join(root, "two.txt"), "original two")
      failure = ->(_path, count) { raise "disk failure" if count == 1 }
      transaction = KnowledgeGraph::Transaction.new(vault_root: root, after_apply: failure)
      transaction.write("one.txt", "changed one")
      transaction.write("two.txt", "changed two")

      error = assert_raises(KnowledgeGraph::TransactionError) { transaction.commit }

      assert_includes error.message, "disk failure"
      assert_equal "original one", File.read(File.join(root, "one.txt"))
      assert_equal "original two", File.read(File.join(root, "two.txt"))
      assert_equal :rolled_back, transaction.state
    end
  end

  def test_aborts_if_a_file_changed_since_it_was_staged
    with_vault do |root|
      path = File.join(root, "person.md")
      File.write(path, "inspected")
      transaction = KnowledgeGraph::Transaction.new(vault_root: root)
      transaction.write("person.md", "engine update")
      File.write(path, "human update")

      error = assert_raises(KnowledgeGraph::TransactionError) { transaction.commit }

      assert_includes error.message, "concurrent modification"
      assert_equal "human update", File.read(path)
    end
  end

  def test_rejects_paths_outside_the_vault
    with_vault do |root|
      transaction = KnowledgeGraph::Transaction.new(vault_root: root)

      assert_raises(KnowledgeGraph::TransactionError) { transaction.write("../escape.md", "no") }
      assert_raises(KnowledgeGraph::TransactionError) { transaction.write("/tmp/escape.md", "no") }
    end
  end
end
