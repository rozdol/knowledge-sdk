# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "pathname"
require "time"

module KnowledgeSDK
  class Migration
    EMBEDDED_PATHS = [
      "_System/KnowledgeGraph", "_System/Tools", "_System/Acceptance Testing"
    ].freeze

    def initialize(vault_root:, backup_root:)
      @vault_root = Pathname.new(vault_root).expand_path
      @backup_root = Pathname.new(backup_root).expand_path
    end

    def migrate!(prune_embedded: false)
      embedded = prune_embedded ? EMBEDDED_PATHS.select { |relative| @vault_root.join(relative).exist? } : []
      runtime_present = @vault_root.join("_System/KnowledgeGraph/Runtime").directory?
      return { "vault" => @vault_root.to_s, "changes" => [], "backup" => nil }.freeze unless runtime_present || !embedded.empty?

      destination = unique_backup_path
      preflight_runtime! if runtime_present
      FileUtils.mkdir_p(destination.join("files"))
      moves = []
      changes = []
      migrate_runtime(moves, changes) if runtime_present
      move_embedded(destination, embedded, changes)
      manifest = build_manifest(embedded, moves)
      destination.join("manifest.json").write(JSON.pretty_generate(manifest) + "\n")
      { "vault" => @vault_root.to_s, "changes" => changes, "backup" => destination.to_s }.freeze
    rescue StandardError => error
      restore_partial(destination, embedded || [], moves || []) if destination
      raise error if error.is_a?(MigrationError)

      raise MigrationError, "migration failed and was rolled back: #{error.message}"
    end

    def rollback!(backup)
      source = Pathname.new(backup).expand_path
      manifest_path = source.join("manifest.json")
      raise MigrationError, "migration backup manifest not found: #{manifest_path}" unless manifest_path.file?

      manifest = JSON.parse(manifest_path.read)
      validate_manifest!(manifest)
      preflight_rollback!(source, manifest)
      restored = []
      manifest.fetch("paths").each do |relative|
        destination = @vault_root.join(relative)
        stored = source.join("files", relative)
        FileUtils.mkdir_p(destination.dirname)
        FileUtils.mv(stored.to_s, destination.to_s)
        restored << relative
      end
      manifest.fetch("moves").reverse_each do |move|
        current = @vault_root.join(move.fetch("to"))
        previous = @vault_root.join(move.fetch("from"))
        FileUtils.mkdir_p(previous.dirname)
        FileUtils.mv(current.to_s, previous.to_s)
        restored << move.fetch("from")
      end
      restored.freeze
    rescue JSON::ParserError, KeyError => error
      raise MigrationError, "invalid migration backup: #{error.message}"
    end

    private

    def preflight_runtime!
      old_root = @vault_root.join("_System/KnowledgeGraph/Runtime")
      new_root = @vault_root.join(KnowledgeSDK::RUNTIME_PATH)
      raise MigrationError, "runtime destination already exists: #{new_root}" if new_root.exist?

      %w[datasets.sqlite3 datasets.sqlite3-wal datasets.sqlite3-shm].each do |filename|
        next unless old_root.join(filename).exist?

        destination = @vault_root.join(dataset_destination(filename))
        raise MigrationError, "dataset destination already exists: #{destination}" if destination.exist?
      end
    end

    def migrate_runtime(moves, changes)
      old_relative = "_System/KnowledgeGraph/Runtime"
      new_relative = KnowledgeSDK::RUNTIME_PATH
      move_with_record(old_relative, new_relative, moves, changes)
      %w[datasets.sqlite3 datasets.sqlite3-wal datasets.sqlite3-shm].each do |filename|
        source = "#{new_relative}/#{filename}"
        next unless @vault_root.join(source).exist?

        move_with_record(source, dataset_destination(filename), moves, changes)
      end
    end

    def dataset_destination(filename)
      KnowledgeSDK::DATASET_PATH + filename.sub("datasets.sqlite3", "")
    end

    def move_with_record(from, to, moves, changes)
      source = @vault_root.join(from)
      destination = @vault_root.join(to)
      FileUtils.mkdir_p(destination.dirname)
      FileUtils.mv(source.to_s, destination.to_s)
      moves << { "from" => from, "to" => to }
      changes << "#{from} -> #{to}"
    end

    def move_embedded(destination, embedded, changes)
      embedded.each do |relative|
        source = @vault_root.join(relative)
        target = destination.join("files", relative)
        FileUtils.mkdir_p(target.dirname)
        FileUtils.mv(source.to_s, target.to_s)
        changes << "#{relative} -> #{target}"
      end
    end

    def build_manifest(embedded, moves)
      fingerprints = moves.each_with_object({}) do |move, result|
        path = @vault_root.join(move.fetch("to"))
        result[move.fetch("to")] = fingerprint(path) if path.exist?
      end
      {
        "version" => 1,
        "vault" => @vault_root.to_s,
        "created_at" => Time.now.utc.iso8601,
        "paths" => embedded,
        "moves" => moves,
        "fingerprints" => fingerprints
      }
    end

    def validate_manifest!(manifest)
      raise MigrationError, "migration backup version is unsupported" unless manifest["version"] == 1
      raise MigrationError, "migration backup belongs to another Vault" unless manifest["vault"] == @vault_root.to_s
      raise MigrationError, "migration paths must be an array" unless manifest["paths"].is_a?(Array)
      raise MigrationError, "migration moves must be an array" unless manifest["moves"].is_a?(Array)
    end

    def preflight_rollback!(backup, manifest)
      manifest.fetch("paths").each do |relative|
        stored = backup.join("files", relative)
        raise MigrationError, "backup payload is missing: #{stored}" unless stored.exist?
        destination = @vault_root.join(relative)
        raise MigrationError, "rollback would replace #{destination}" if destination.exist?
      end
      manifest.fetch("moves").reverse_each do |move|
        current = @vault_root.join(move.fetch("to"))
        previous = @vault_root.join(move.fetch("from"))
        raise MigrationError, "migrated payload is missing: #{current}" unless current.exist?
        raise MigrationError, "rollback would replace #{previous}" if previous.exist?
        expected = manifest.fetch("fingerprints", {})[move.fetch("to")]
        next unless expected

        actual = fingerprint(current)
        raise MigrationError, "migrated data changed after migration: #{current}" unless actual == expected
      end
    end

    def restore_partial(destination, embedded, moves)
      embedded.reverse_each do |relative|
        stored = destination.join("files", relative)
        next unless stored.exist?

        target = @vault_root.join(relative)
        FileUtils.mkdir_p(target.dirname)
        FileUtils.mv(stored.to_s, target.to_s) unless target.exist?
      end
      moves.reverse_each do |move|
        current = @vault_root.join(move.fetch("to"))
        previous = @vault_root.join(move.fetch("from"))
        next unless current.exist? && !previous.exist?

        FileUtils.mkdir_p(previous.dirname)
        FileUtils.mv(current.to_s, previous.to_s)
      end
    rescue StandardError
      nil
    end

    def unique_backup_path
      stamp = Time.now.utc.strftime("%Y%m%dT%H%M%S")
      candidate = @backup_root.join("migration-#{stamp}-#{Process.pid}")
      raise MigrationError, "migration backup already exists: #{candidate}" if candidate.exist?

      candidate
    end

    def fingerprint(path)
      digest = Digest::SHA256.new
      if path.file?
        digest.update("file\0")
        digest.update(path.binread)
      else
        Dir.glob(path.join("**/*").to_s, File::FNM_DOTMATCH).sort.each do |entry|
          item = Pathname.new(entry)
          next unless item.file?

          digest.update(item.relative_path_from(path).to_s)
          digest.update("\0")
          digest.update(item.binread)
          digest.update("\0")
        end
      end
      digest.hexdigest
    end
  end
end
