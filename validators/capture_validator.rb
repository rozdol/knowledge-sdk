# frozen_string_literal: true

require "date"
require "pathname"
require "time"
require "uri"
require "yaml"

module KnowledgeCaptureValidator
  KINDS = %w[
    thought idea note question lesson decision observation bookmark reference quote hypothesis
  ].freeze
  STATUSES = %w[inbox reviewed linked promoted archived deleted].freeze
  REQUIRED = %w[
    id capture_id type schema_version kind title captured_at created_at updated_at created_by updated_by
    importance status review_state record_status topics tags language related_entities related_projects
    related_contacts evidence source sensitivity
  ].freeze
  ARRAY_FIELDS = %w[
    topics tags collections related_entities related_projects related_contacts evidence promoted_to
  ].freeze
  BOOKMARK_REQUIRED = %w[url canonical_url domain resource_type fetch_status].freeze
  RESOURCE_TYPES = %w[
    article personal_website portfolio gallery photo_gallery blog documentation project
    reference video_page product_page repository forum_thread unknown
  ].freeze
  FETCH_STATUSES = %w[not_attempted succeeded failed].freeze
  ULID = /\A[0-9A-HJKMNP-TV-Z]{26}\z/.freeze

  module_function

  def validate(root)
    vault = Pathname.new(root).expand_path
    Dir.glob(vault.join("Captures/**/*.md").to_s).sort.each_with_object([]) do |filename, errors|
      path = Pathname.new(filename)
      relative = path.relative_path_from(vault).to_s
      content = path.read(encoding: "UTF-8")
      match = content.match(/\A---\s*\r?\n(.*?)\r?\n---\s*(?:\r?\n|\z)/m)
      unless match
        errors << "#{relative}: Capture requires closed YAML frontmatter"
        next
      end
      data = YAML.safe_load(match[1], permitted_classes: [Date, Time], aliases: false)
      unless data.is_a?(Hash)
        errors << "#{relative}: Capture frontmatter must be a mapping"
        next
      end
      data = data.transform_keys(&:to_s)
      body = content[match.end(0)..-1].to_s
      REQUIRED.each do |field|
        value = data[field]
        present = data.key?(field) && !value.nil? && (!value.is_a?(String) || !value.strip.empty?)
        errors << "#{relative}: missing Capture field #{field}" unless present
      end
      unless flat?(data)
        errors << "#{relative}: Capture frontmatter must contain only scalars and flat scalar lists"
      end
      ARRAY_FIELDS.each do |field|
        errors << "#{relative}: Capture #{field} must be a list" if data.key?(field) && !data[field].is_a?(Array)
      end
      capture_id = data["capture_id"].to_s
      errors << "#{relative}: Capture id and capture_id must match" unless data["id"].to_s == capture_id
      prefix, suffix = capture_id.split("_", 2)
      errors << "#{relative}: invalid immutable Capture ID" unless prefix == "capture" && suffix&.match?(ULID)
      errors << "#{relative}: filename must equal immutable Capture ID" unless path.basename(".md").to_s == capture_id
      errors << "#{relative}: type must be capture" unless data["type"] == "capture"
      unless [1, 2].include?(data["schema_version"])
        errors << "#{relative}: Capture schema_version must be 1 or 2"
      end
      errors << "#{relative}: invalid Capture kind #{data['kind'].inspect}" unless KINDS.include?(data["kind"])
      errors << "#{relative}: invalid Capture status #{data['status'].inspect}" unless STATUSES.include?(data["status"])
      unless %w[unreviewed reviewed].include?(data["review_state"])
        errors << "#{relative}: invalid Capture review_state #{data['review_state'].inspect}"
      end
      unless %w[low normal high critical].include?(data["importance"])
        errors << "#{relative}: invalid Capture importance #{data['importance'].inspect}"
      end
      unless %w[normal private restricted].include?(data["sensitivity"])
        errors << "#{relative}: invalid Capture sensitivity #{data['sensitivity'].inspect}"
      end
      %w[captured_at created_at updated_at].each do |field|
        begin
          Time.iso8601(data[field].to_s)
        rescue ArgumentError
          errors << "#{relative}: Capture #{field} must be ISO 8601"
        end
      end
      expected_record_status = %w[archived deleted].include?(data["status"]) ? "archived" : "active"
      unless data["record_status"] == expected_record_status
        errors << "#{relative}: Capture record_status does not match lifecycle status"
      end
      if data["status"] == "promoted" && (data["promotion_kind"].to_s.empty? || Array(data["promoted_to"]).empty?)
        errors << "#{relative}: promoted Capture requires promotion_kind and promoted_to"
      end
      validate_bookmark(data, relative, errors)
      errors << "#{relative}: Capture Markdown body is required" if body.strip.empty?
    rescue Psych::SyntaxError => error
      errors << "#{relative}: Capture YAML error: #{error.message.lines.first.strip}"
    rescue Encoding::InvalidByteSequenceError, Encoding::UndefinedConversionError
      errors << "#{relative}: Capture must be valid UTF-8"
    end
  end

  def flat?(data)
    data.values.none? do |value|
      value.is_a?(Hash) || (value.is_a?(Array) && value.any? { |item| item.is_a?(Hash) || item.is_a?(Array) })
    end
  end

  def validate_bookmark(data, relative, errors)
    return unless data["schema_version"] == 2 || data["kind"] == "bookmark" && data.key?("url")

    errors << "#{relative}: Capture schema_version 2 is reserved for bookmarks" unless data["kind"] == "bookmark"
    errors << "#{relative}: URL-backed bookmark requires Capture schema_version 2" unless data["schema_version"] == 2
    BOOKMARK_REQUIRED.each do |field|
      errors << "#{relative}: missing bookmark field #{field}" if data[field].to_s.strip.empty?
    end
    unless RESOURCE_TYPES.include?(data["resource_type"])
      errors << "#{relative}: invalid bookmark resource_type #{data['resource_type'].inspect}"
    end
    unless FETCH_STATUSES.include?(data["fetch_status"])
      errors << "#{relative}: invalid bookmark fetch_status #{data['fetch_status'].inspect}"
    end
    if data.key?("reading_status") && !%w[unread reading read].include?(data["reading_status"])
      errors << "#{relative}: invalid bookmark reading_status #{data['reading_status'].inspect}"
    end
    %w[url canonical_url].each do |field|
      begin
        uri = URI.parse(data[field].to_s)
        unless uri.is_a?(URI::HTTP) && %w[http https].include?(uri.scheme.to_s.downcase) && !uri.host.to_s.empty?
          errors << "#{relative}: bookmark #{field} must be an HTTP(S) URL"
        end
      rescue URI::InvalidURIError
        errors << "#{relative}: bookmark #{field} must be an HTTP(S) URL"
      end
    end
    canonical_host = URI.parse(data["canonical_url"].to_s).host.to_s.downcase rescue ""
    unless canonical_host.empty? || canonical_host == data["domain"].to_s.downcase
      errors << "#{relative}: bookmark domain must match canonical_url"
    end
    if data.key?("content_hash") && !data["content_hash"].to_s.match?(/\A[0-9a-f]{64}\z/)
      errors << "#{relative}: bookmark content_hash must be SHA-256"
    end
    {
      "url" => 4_096, "canonical_url" => 4_096, "author_name" => 500,
      "description" => 2_000, "content_excerpt" => 4_000
    }.each do |field, maximum|
      if data[field].to_s.length > maximum
        errors << "#{relative}: bookmark #{field} exceeds #{maximum} characters"
      end
    end
    if data["fetch_status"] != "not_attempted"
      begin
        Time.iso8601(data["fetched_at"].to_s)
      rescue ArgumentError
        errors << "#{relative}: fetched bookmark requires ISO 8601 fetched_at"
      end
    end
  end
end
