# frozen_string_literal: true

require "digest"
require "fileutils"
require "pathname"
require "tempfile"
require "tmpdir"

module KnowledgeGraph
  class Transaction
    Snapshot = Struct.new(:exists, :content, :mode, :fingerprint, keyword_init: true)

    attr_reader :state

    def initialize(vault_root:, after_apply: nil)
      @vault_root = Pathname.new(vault_root).expand_path
      @after_apply = after_apply
      @writes = {}
      @deletes = {}
      @snapshots = {}
      @state = :open
    end

    def write(relative_path, content)
      ensure_open!
      relative = normalize(relative_path)
      capture(relative)
      @deletes.delete(relative)
      @writes[relative] = content.to_s.dup.freeze
      self
    end

    def delete(relative_path)
      ensure_open!
      relative = normalize(relative_path)
      capture(relative)
      @writes.delete(relative)
      @deletes[relative] = true
      self
    end

    def move(source, destination)
      ensure_open!
      source = normalize(source)
      destination = normalize(destination)
      content = read(source)
      raise EntityNotFound, "cannot move missing path #{source}" if content.nil?

      write(destination, content)
      delete(source)
      self
    end

    def read(relative_path)
      ensure_open!
      relative = normalize(relative_path)
      return @writes.fetch(relative) if @writes.key?(relative)
      return nil if @deletes.key?(relative)

      path = absolute(relative)
      path.file? ? path.binread : nil
    end

    def exist?(relative_path)
      !read(relative_path).nil?
    end

    def changed_paths
      (@writes.keys + @deletes.keys).uniq.sort.freeze
    end

    def materialize_to(destination_root)
      ensure_open!
      root = Pathname.new(destination_root)
      @writes.each do |relative, content|
        destination = root.join(relative)
        FileUtils.mkdir_p(destination.dirname)
        destination.delete if destination.file?
        destination.binwrite(content)
      end
      @deletes.each_key do |relative|
        destination = root.join(relative)
        destination.delete if destination.file?
      end
      destination_root
    end

    def commit
      ensure_open!
      verified = false
      with_lock do
        verify_unchanged!
        verified = true
        apply_changes!
      end
      @state = :committed
      self
    rescue StandardError => error
      if verified
        rollback_after_failure(error)
      else
        @state = :rolled_back
        raise TransactionError, error.message, error.backtrace
      end
    end

    def rollback
      return self if @state == :rolled_back
      raise TransactionError, "cannot roll back a committed transaction" if @state == :committed

      @writes.clear
      @deletes.clear
      @state = :rolled_back
      self
    end

    private

    def normalize(relative_path)
      raw = relative_path.to_s
      candidate = Pathname.new(raw)
      clean = candidate.cleanpath.to_s
      invalid = raw.empty? || raw.include?("\0") || candidate.absolute? || clean == "." ||
                clean == ".." || clean.start_with?("../")
      raise TransactionError, "path must stay inside the vault: #{raw.inspect}" if invalid

      clean
    end

    def absolute(relative)
      path = @vault_root.join(relative)
      current = path
      until current == @vault_root
        raise TransactionError, "symlink paths are not writable: #{relative}" if current.symlink?
        current = current.parent
      end
      path
    end

    def capture(relative)
      @snapshots[relative] ||= snapshot(relative)
    end

    def snapshot(relative)
      path = absolute(relative)
      return Snapshot.new(exists: false, fingerprint: fingerprint(nil)).freeze unless path.file?

      content = path.binread
      Snapshot.new(
        exists: true,
        content: content.freeze,
        mode: path.stat.mode & 0o777,
        fingerprint: fingerprint(content)
      ).freeze
    end

    def fingerprint(content)
      content.nil? ? :missing : Digest::SHA256.hexdigest(content)
    end

    def verify_unchanged!
      @snapshots.each do |relative, original|
        current = snapshot(relative)
        next if current.exists == original.exists && current.fingerprint == original.fingerprint

        raise TransactionError, "concurrent modification detected for #{relative}"
      end
    end

    def with_lock
      digest = Digest::SHA256.hexdigest(@vault_root.to_s)
      lock_path = File.join(Dir.tmpdir, "knowledge-graph-#{digest}.lock")
      File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        yield
      ensure
        lock.flock(File::LOCK_UN) rescue nil
      end
    end

    def apply_changes!
      applied = 0
      @writes.keys.sort.each do |relative|
        atomic_write(absolute(relative), @writes.fetch(relative), @snapshots.fetch(relative).mode)
        applied += 1
        @after_apply&.call(relative, applied)
      end
      @deletes.keys.sort.each do |relative|
        path = absolute(relative)
        path.delete if path.file?
        applied += 1
        @after_apply&.call(relative, applied)
      end
    end

    def atomic_write(path, content, mode = nil)
      FileUtils.mkdir_p(path.dirname)
      Tempfile.create([".#{path.basename}", ".kg-tmp"], path.dirname.to_s) do |temporary|
        temporary.binmode
        temporary.write(content)
        temporary.flush
        temporary.fsync
        temporary.chmod(mode || 0o644)
        temporary.close
        File.rename(temporary.path, path.to_s)
      end
    end

    def rollback_after_failure(original_error)
      begin
        restore_snapshots!
      rescue StandardError => rollback_error
        @state = :rolled_back
        raise TransactionError,
              "transaction failed (#{original_error.message}); rollback failed (#{rollback_error.message})"
      end
      @state = :rolled_back
      raise TransactionError, original_error.message, original_error.backtrace
    end

    def restore_snapshots!
      @snapshots.each do |relative, original|
        path = absolute(relative)
        if original.exists
          atomic_write(path, original.content, original.mode)
        else
          path.delete if path.file?
        end
      end
    rescue StandardError => error
      raise TransactionError, error.message
    end

    def ensure_open!
      raise TransactionError, "transaction is #{@state}" unless @state == :open
    end
  end
end
