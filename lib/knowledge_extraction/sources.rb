# frozen_string_literal: true

require "digest"

module KnowledgeExtraction
  class SourceDocument < ImmutableModel
    TYPES = %w[
      text chat meeting-notes email-text transcript ocr-text image-ocr pdf-text csv excel
    ].freeze

    attr_reader :source_id, :source_type, :content, :language, :captured_at,
                :source_uri, :external_id, :title, :author, :participants,
                :metadata, :content_hash

    def initialize(source_type:, content:, source_id: nil, language: "und", captured_at: nil,
                   source_uri: nil, external_id: nil, title: nil, author: nil,
                   participants: [], metadata: {}, content_hash: nil)
      @source_type = source_type.to_s
      raise UnsupportedSource, "unsupported source type #{@source_type.inspect}" unless TYPES.include?(@source_type)

      @content = Support.normalized_text(content).freeze
      raise NormalizationFailure, "source content is empty" if @content.strip.empty?

      @language = language.to_s.empty? ? "und" : language.to_s.freeze
      @captured_at = Support.parse_time(captured_at, field: "captured_at")
      @source_uri = optional_string(source_uri, "source_uri", maximum: 4_096)
      @external_id = optional_string(external_id, "external_id", maximum: 1_000)
      @title = optional_string(title, "title", maximum: 1_000)
      @author = optional_string(author, "author", maximum: 1_000)
      @participants = immutable(Array(participants).map(&:to_s))
      @metadata = immutable(metadata || {})
      computed_hash = Digest::SHA256.hexdigest(@content)
      if content_hash && content_hash.to_s != computed_hash
        raise NormalizationFailure, "content_hash does not match normalized content"
      end
      @content_hash = computed_hash.freeze
      identity = external_id || source_uri || computed_hash
      @source_id = (source_id || Support.stable_id("source", @source_type, identity)).to_s.freeze
      freeze
    end

    def to_h(include_content: true)
      value = {
        source_id: source_id, source_type: source_type, content: content, language: language,
        captured_at: captured_at&.iso8601, source_uri: source_uri, external_id: external_id,
        title: title, author: author, participants: participants, metadata: metadata,
        content_hash: content_hash
      }
      value.delete(:content) unless include_content
      value
    end

    def metadata_only
      to_h(include_content: false)
    end
  end

  class SourceNormalizer
    LANGUAGE_PATTERNS = {
      "ru" => /[А-Яа-яЁё]/,
      "el" => /\p{Greek}/
    }.freeze

    def initialize(configuration: Configuration.new)
      @configuration = configuration
    end

    def normalize(source, source_type: nil, **metadata)
      document = if source.is_a?(SourceDocument)
                   source
                 else
                   SourceDocument.new(source_type: source_type || "text", content: source, **metadata)
                 end
      if document.content.bytesize > @configuration.source_size_limit
        raise NormalizationFailure, "source exceeds #{@configuration.source_size_limit} bytes"
      end
      language = document.language == "und" ? detect_language(document.content) : document.language
      unless @configuration.supported_languages.include?(language)
        raise UnsupportedSource, "unsupported source language #{language.inspect}"
      end
      return document if language == document.language

      SourceDocument.new(**document.to_h.merge(language: language).transform_keys(&:to_sym))
    end

    private

    def detect_language(content)
      detected = LANGUAGE_PATTERNS.keys.select { |key| content.match?(LANGUAGE_PATTERNS.fetch(key)) }
      has_latin = content.match?(/[A-Za-z]/)
      return "mixed" if detected.length > 1 || (has_latin && !detected.empty?)
      return detected.first unless detected.empty?
      return "en" if has_latin

      "und"
    end
  end

  class SourceAdapter
    attr_reader :source_type

    def initialize(source_type)
      @source_type = source_type.freeze
    end

    def build(content, **metadata)
      SourceDocument.new(source_type: source_type, content: content, **metadata)
    end

    def self.for(source_type)
      type = source_type.to_s
      raise UnsupportedSource, "unsupported source type #{type.inspect}" unless SourceDocument::TYPES.include?(type)

      new(type)
    end
  end

  TextSourceAdapter = Class.new(SourceAdapter) { def initialize; super("text"); end }
  ChatSourceAdapter = Class.new(SourceAdapter) { def initialize; super("chat"); end }
  MeetingNotesSourceAdapter = Class.new(SourceAdapter) { def initialize; super("meeting-notes"); end }
  EmailTextSourceAdapter = Class.new(SourceAdapter) { def initialize; super("email-text"); end }
  TranscriptSourceAdapter = Class.new(SourceAdapter) { def initialize; super("transcript"); end }
  OCRTextSourceAdapter = Class.new(SourceAdapter) { def initialize; super("ocr-text"); end }
  PDFTextSourceAdapter = Class.new(SourceAdapter) { def initialize; super("pdf-text"); end }
end
