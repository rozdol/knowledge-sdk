# frozen_string_literal: true

require "time"

module KnowledgeCapture
  class Capture
    KINDS = %w[
      thought idea note question lesson decision observation bookmark reference quote hypothesis
    ].freeze
    STATUSES = %w[inbox reviewed linked promoted archived deleted].freeze
    REVIEW_STATES = %w[unreviewed reviewed].freeze
    IMPORTANCE_LEVELS = %w[low normal high critical].freeze
    SENSITIVITY_LEVELS = %w[normal private restricted].freeze

    attr_reader :id, :kind, :title, :body, :captured_at, :created_by,
                :importance, :status, :review_state, :topics, :tags,
                :language, :related_entities, :related_projects,
                :related_contacts, :evidence, :source, :sensitivity,
                :promotion_kind, :promoted_to, :relative_path, :data

    def initialize(data:, body:, relative_path:)
      values = data.transform_keys(&:to_s)
      @id = required(values["capture_id"] || values["id"], "capture_id")
      unless @id.match?(/\Acapture_[0-9A-HJKMNP-TV-Z]{26}\z/)
        raise InvalidCapture, "invalid capture ID"
      end
      @kind = required(values["kind"], "kind")
      raise InvalidCapture, "unsupported capture kind #{@kind.inspect}" unless KINDS.include?(@kind)
      @title = required(values["title"], "title")
      @body = body.to_s.dup.freeze
      raise InvalidCapture, "capture body is required" if @body.strip.empty?
      @captured_at = parse_time(values["captured_at"])
      @created_by = required(values["created_by"], "created_by")
      @importance = (values["importance"] || "normal").to_s.freeze
      unless IMPORTANCE_LEVELS.include?(@importance)
        raise InvalidCapture, "invalid capture importance #{@importance.inspect}"
      end
      @status = required(values["status"], "status")
      raise InvalidCapture, "invalid capture status #{@status.inspect}" unless STATUSES.include?(@status)
      @review_state = required(values["review_state"], "review_state")
      unless REVIEW_STATES.include?(@review_state)
        raise InvalidCapture, "invalid capture review state #{@review_state.inspect}"
      end
      @topics = strings(values["topics"])
      @tags = strings(values["tags"])
      @language = (values["language"] || "und").to_s.freeze
      @related_entities = strings(values["related_entities"])
      @related_projects = strings(values["related_projects"])
      @related_contacts = strings(values["related_contacts"])
      @evidence = strings(values["evidence"])
      @source = (values["source"] || "unknown").to_s.freeze
      @sensitivity = (values["sensitivity"] || "private").to_s.freeze
      unless SENSITIVITY_LEVELS.include?(@sensitivity)
        raise InvalidCapture, "invalid capture sensitivity #{@sensitivity.inspect}"
      end
      @promotion_kind = values["promotion_kind"] && values["promotion_kind"].to_s.freeze
      @promoted_to = strings(values["promoted_to"])
      @relative_path = relative_path.to_s.freeze
      @data = immutable(values)
      freeze
    end

    def active?
      !%w[archived deleted].include?(status)
    end

    def public_h(include_id: false, include_body: true)
      value = {
        "kind" => kind, "title" => title, "captured_at" => captured_at.iso8601,
        "importance" => importance, "status" => status,
        "review_state" => review_state, "topics" => topics, "tags" => tags,
        "language" => language, "source" => source, "sensitivity" => sensitivity,
        "promotion_kind" => promotion_kind
      }.reject { |_key, item| item.nil? || (item.respond_to?(:empty?) && item.empty?) }
      value["body"] = body if include_body
      if include_id
        value.merge!(
          "capture_id" => id, "related_entities" => related_entities,
          "related_projects" => related_projects, "related_contacts" => related_contacts,
          "evidence" => evidence, "promoted_to" => promoted_to
        )
      end
      value
    end

    private

    def required(value, field)
      string = value.to_s.strip
      raise InvalidCapture, "#{field} is required" if string.empty?

      string.freeze
    end

    def strings(value)
      Array(value).map(&:to_s).reject(&:empty?).uniq.freeze
    end

    def parse_time(value)
      (value.is_a?(Time) ? value : Time.iso8601(value.to_s)).freeze
    rescue ArgumentError
      raise InvalidCapture, "captured_at must be ISO 8601"
    end

    def immutable(value)
      case value
      when Hash
        value.each_with_object({}) { |(key, item), result| result[key.to_s.freeze] = immutable(item) }.freeze
      when Array then value.map { |item| immutable(item) }.freeze
      when String then value.dup.freeze
      else value.frozen? ? value : value.dup.freeze
      end
    rescue TypeError
      value.freeze
    end
  end
end
