# frozen_string_literal: true

require "fileutils"
require "json"
require "pathname"
require "tempfile"

module KnowledgeExtraction
  class EvidenceSpan < ImmutableModel
    attr_reader :evidence_id, :source_id, :start_offset, :end_offset, :excerpt,
                :page, :paragraph, :speaker, :timestamp_start, :timestamp_end

    def initialize(source_id:, excerpt:, evidence_id: nil, start_offset: nil, end_offset: nil,
                   page: nil, paragraph: nil, speaker: nil, timestamp_start: nil, timestamp_end: nil)
      @source_id = required_string(source_id, "source_id", maximum: 200)
      @excerpt = required_string(excerpt, "excerpt", maximum: 2_000)
      @start_offset = optional_nonnegative_integer(start_offset, "start_offset")
      @end_offset = optional_nonnegative_integer(end_offset, "end_offset")
      if @start_offset.nil? != @end_offset.nil?
        raise EvidenceMismatch, "start_offset and end_offset must be supplied together"
      end
      if @start_offset && @end_offset <= @start_offset
        raise EvidenceMismatch, "end_offset must be greater than start_offset"
      end
      @page = optional_positive_integer(page, "page")
      @paragraph = optional_positive_integer(paragraph, "paragraph")
      @speaker = optional_string(speaker, "speaker", maximum: 300)
      @timestamp_start = optional_nonnegative_number(timestamp_start, "timestamp_start")
      @timestamp_end = optional_nonnegative_number(timestamp_end, "timestamp_end")
      if @timestamp_start && @timestamp_end && @timestamp_end < @timestamp_start
        raise EvidenceMismatch, "timestamp_end must not precede timestamp_start"
      end
      if @start_offset.nil? && @page.nil? && @timestamp_start.nil?
        raise EvidenceMismatch, "evidence needs offsets, a page, or a timestamp"
      end
      @evidence_id = (evidence_id || Support.stable_id(
        "evidence", @source_id, @start_offset, @end_offset, @page, @timestamp_start, @excerpt
      )).to_s.freeze
      freeze
    end

    def validate!(document)
      raise EvidenceMismatch, "evidence source_id does not match document" unless source_id == document.source_id
      return self unless start_offset
      if end_offset > document.content.length
        raise EvidenceMismatch, "evidence offsets exceed source length"
      end
      actual = document.content[start_offset...end_offset]
      raise EvidenceMismatch, "evidence excerpt does not match source offsets" unless actual == excerpt

      self
    end

    def to_h
      Support.compact_hash(
        evidence_id: evidence_id, source_id: source_id, start_offset: start_offset,
        end_offset: end_offset, excerpt: excerpt, page: page, paragraph: paragraph,
        speaker: speaker, timestamp_start: timestamp_start, timestamp_end: timestamp_end
      )
    end

    private

    def optional_nonnegative_integer(value, field)
      return nil if value.nil?
      number = Integer(value)
      raise EvidenceMismatch, "#{field} must be non-negative" if number.negative?
      number
    rescue ArgumentError, TypeError
      raise EvidenceMismatch, "#{field} must be a non-negative integer"
    end

    def optional_positive_integer(value, field)
      return nil if value.nil?
      number = Integer(value)
      raise EvidenceMismatch, "#{field} must be positive" unless number.positive?
      number
    rescue ArgumentError, TypeError
      raise EvidenceMismatch, "#{field} must be a positive integer"
    end

    def optional_nonnegative_number(value, field)
      return nil if value.nil?
      number = Float(value)
      raise EvidenceMismatch, "#{field} must be non-negative" if number.negative?
      number
    rescue ArgumentError, TypeError
      raise EvidenceMismatch, "#{field} must be non-negative"
    end
  end

  # Local immutable source evidence. The proposal keeps bounded spans while
  # this store preserves the complete normalized rendition and the URI of the
  # original artifact (for example the PDF retained by Hermes/object storage).
  class SourceEvidenceStore
    ROOT = ".knowledge/evidence/sources".freeze

    def initialize(vault_root:)
      @root = Pathname.new(vault_root).expand_path.join(ROOT)
    end

    def save(document)
      raise ArgumentError, "source evidence requires a SourceDocument" unless document.is_a?(SourceDocument)

      payload = JSON.pretty_generate(document.to_h) + "\n"
      path = path_for(document.source_id, content_hash: document.content_hash)
      if path.file?
        existing = JSON.parse(path.read)
        unless existing["content_hash"] == document.content_hash && existing["content"] == document.content
          raise PlanningFailure, "source evidence ID collision with different content"
        end
        return path
      end
      FileUtils.mkdir_p(path.dirname)
      Tempfile.create([".#{path.basename}", ".tmp"], path.dirname.to_s) do |file|
        file.write(payload)
        file.flush
        file.fsync
        file.close
        File.rename(file.path, path.to_s)
      end
      path
    rescue JSON::ParserError => error
      raise PlanningFailure, "stored source evidence is invalid JSON: #{error.message}"
    end

    def load(source_id, content_hash: nil)
      path = if content_hash
               path_for(source_id, content_hash: content_hash)
             else
               paths = Dir[path_for(source_id).join("*.json").to_s].sort
               raise PlanningFailure, "source evidence not found: #{source_id}" if paths.empty?

               Pathname.new(paths.last)
             end
      raise PlanningFailure, "source evidence not found: #{source_id}" unless path.file?

      JSON.parse(path.read)
    rescue JSON::ParserError => error
      raise PlanningFailure, "stored source evidence is invalid JSON: #{error.message}"
    end

    def path_for(source_id, content_hash: nil)
      value = source_id.to_s
      unless value.match?(/\Asource_[0-9A-HJKMNP-TV-Z]{26}\z/)
        raise PlanningFailure, "invalid source evidence ID"
      end

      directory = @root.join(value)
      return directory if content_hash.nil?

      digest = content_hash.to_s
      unless digest.match?(/\A[0-9a-f]{64}\z/)
        raise PlanningFailure, "invalid source evidence content hash"
      end
      directory.join("#{digest}.json")
    end
  end
end
