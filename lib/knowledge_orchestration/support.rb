# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "tempfile"
require "time"

module KnowledgeOrchestration
  module Stable
    ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ".freeze
    module_function

    def json(value)
      AgentPlatform::Value.canonical_json(value)
    end

    def digest(value)
      Digest::SHA256.hexdigest(json(value))
    end

    def id(prefix, *parts)
      number = Digest::SHA256.digest(json(parts)).unpack1("H*").to_i(16)
      encoded = 26.times.map do
        character = ALPHABET[number % 32]
        number /= 32
        character
      end.reverse.join
      "#{prefix}_#{encoded}"
    end
  end

  module AtomicFile
    module_function

    def write_json(path, value)
      target = File.expand_path(path.to_s)
      FileUtils.mkdir_p(File.dirname(target))
      Tempfile.create([".orchestration", ".tmp"], File.dirname(target)) do |file|
        file.write(JSON.pretty_generate(AgentPlatform::Value.canonical(value)) + "\n")
        file.flush
        file.fsync
        file.close
        File.rename(file.path, target)
      end
      target
    end

    def append_jsonl(path, value)
      target = File.expand_path(path.to_s)
      FileUtils.mkdir_p(File.dirname(target))
      File.open(target, File::WRONLY | File::APPEND | File::CREAT, 0o600) do |file|
        file.flock(File::LOCK_EX)
        file.write(JSON.generate(AgentPlatform::Value.canonical(value)) + "\n")
        file.flush
        file.fsync
      ensure
        file.flock(File::LOCK_UN)
      end
      target
    end

    def read_json(path, error_class: Error)
      JSON.parse(File.read(path.to_s))
    rescue JSON::ParserError => error
      raise error_class, "invalid runtime JSON #{path}: #{error.message}"
    end

    def read_jsonl(path, error_class: Error)
      return [] unless File.file?(path.to_s)

      File.readlines(path.to_s).each_with_index.each_with_object([]) do |(line, index), result|
        next if line.strip.empty?

        result << JSON.parse(line)
      rescue JSON::ParserError => error
        raise error_class, "invalid runtime JSONL #{path}:#{index + 1}: #{error.message}"
      end
    end
  end
end
