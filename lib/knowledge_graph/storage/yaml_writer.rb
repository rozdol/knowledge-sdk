# frozen_string_literal: true

require "date"
require "json"
require "time"

module KnowledgeGraph
  class YamlWriter
    PROPERTY_ORDER = %w[
      id type schema_version name aliases record_status created_at updated_at created_by updated_by
      created_by_run updated_by_run tags merged_into tier sensitivity data_origin is_self legal_name
      former_names nicknames transliterations emails primary_email phones primary_phone external_ids
      birth_date pronouns life_status contact_policy cadence_target_days preferred_channel timezone review_on
      org_kind country iso_alpha2 place_kind authors project_status starts_at ends_at participants
      dataset_slug dataset_kind dataset_template dataset_template_version dataset_template_digest
      storage_backend storage_table purpose owner_id
      interaction_kind contact_weight event_kind commitment_kind promisor promise_to action commitment_status
      made_on owner followup_status due_on completed_on interest_kind technology_kind introducer introducer_id
      person_a person_a_id person_b person_b_id subject subject_id predicate object object_id recipient
      recipient_id relationship_status assertion_status confidence asserted_by asserted_at asserted_by_run
      occurred_on valid_from valid_to observed_on context_links source_links source_urls data_notes
    ].freeze

    ORDER_INDEX = PROPERTY_ORDER.each_with_index.to_h.freeze

    def render(frontmatter, body: "")
      data = normalize(frontmatter)
      lines = ordered_keys(data).flat_map { |key| emit_pair(key, data.fetch(key)) }
      rendered_body = body.to_s
      "---\n#{lines.join("\n")}\n---\n#{rendered_body}"
    end

    private

    def normalize(frontmatter)
      frontmatter.each_with_object({}) do |(key, value), result|
        key = key.to_s
        raise ValidationError, "frontmatter key must not be empty" if key.empty?
        validate_value!(key, value)
        result[key] = value
      end
    end

    def validate_value!(key, value)
      return unless value.is_a?(Hash) || (value.is_a?(Array) && value.any? { |item| item.is_a?(Array) || item.is_a?(Hash) })

      raise ValidationError, "#{key}: canonical frontmatter must contain only scalars or flat scalar lists"
    end

    def ordered_keys(data)
      data.keys.sort_by { |key| [ORDER_INDEX.fetch(key, PROPERTY_ORDER.length), key] }
    end

    def emit_pair(key, value)
      if value.is_a?(Array)
        return ["#{key}: []"] if value.empty?

        ["#{key}:"] + value.map { |item| "  - #{scalar(item)}" }
      else
        ["#{key}: #{scalar(value)}"]
      end
    end

    def scalar(value)
      case value
      when String then JSON.generate(value)
      when Date then value.iso8601
      when Time then JSON.generate(value.iso8601)
      when Integer, Float then value.to_s
      when TrueClass then "true"
      when FalseClass then "false"
      when NilClass then "null"
      else
        raise ValidationError, "unsupported YAML scalar #{value.class}"
      end
    end
  end
end
