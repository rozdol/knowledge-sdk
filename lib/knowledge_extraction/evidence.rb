# frozen_string_literal: true

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
end
