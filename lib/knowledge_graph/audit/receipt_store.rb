# frozen_string_literal: true

require "digest"
require "json"
require "pathname"

module KnowledgeGraph
  class ReceiptStore
    RUNTIME_PREFIX = "_System/KnowledgeGraph/Runtime/".freeze

    def initialize(vault_root:)
      @vault_root = Pathname.new(vault_root)
    end

    def fingerprint(intent)
      Digest::SHA256.hexdigest(JSON.generate(canonical(intent.to_h)))
    end

    def fetch(fingerprint)
      path = @vault_root.join(relative_path(fingerprint))
      return nil unless path.file?

      data = JSON.parse(path.read)
      result = data.fetch("result")
      Result.new(
        intent_type: result.fetch("intent_type"),
        entity_ids: result.fetch("entity_ids", []),
        changed_paths: result.fetch("changed_paths", []),
        value: result["value"],
        replayed: true
      )
    rescue JSON::ParserError, KeyError => error
      raise AuditError, "invalid idempotency receipt #{path}: #{error.message}"
    end

    def stage(transaction, fingerprint, intent, result)
      payload = {
        "fingerprint" => fingerprint,
        "intent" => intent_payload(intent),
        "result" => result_payload(result)
      }
      transaction.write(relative_path(fingerprint), JSON.pretty_generate(payload) + "\n")
    end

    def intent_payload(intent)
      attributes = intent.to_h.dup
      type = attributes.delete(:intent_type)
      { "type" => type, "params" => canonical(attributes) }
    end

    private

    def result_payload(result)
      {
        "intent_type" => result.intent_type,
        "entity_ids" => result.entity_ids,
        "changed_paths" => result.changed_paths,
        "value" => result.value
      }
    end

    def relative_path(fingerprint)
      raise AuditError, "invalid receipt fingerprint" unless fingerprint.match?(/\A[0-9a-f]{64}\z/)

      "#{RUNTIME_PREFIX}receipts/#{fingerprint}.json"
    end

    def canonical(value)
      case value
      when Hash
        value.keys.sort_by(&:to_s).each_with_object({}) do |key, result|
          result[key.to_s] = canonical(value.fetch(key))
        end
      when Array then value.map { |item| canonical(item) }
      when Time then value.iso8601
      when Date then value.iso8601
      else value
      end
    end
  end
end
