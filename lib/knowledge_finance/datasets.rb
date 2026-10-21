# frozen_string_literal: true

module KnowledgeFinance
  module Schemas
    module_function

    def events
      StructuredDataset::Definition.from_h(
        slug: "finance_events", name: "Financial Ledger", kind: "finance_events",
        purpose: "Immutable economic events; quantities and balances are projections", sensitivity: "private",
        columns: [
          { name: "event_id", type: "TEXT", required: true, unique: true },
          { name: "deduplication_key", type: "TEXT", required: true, unique: true },
          { name: "operation", type: "TEXT", required: true, enum: Projection::OPERATIONS },
          { name: "effective_at", type: "DATETIME", required: true, index: true },
          { name: "booked_at", type: "DATETIME", required: true },
          { name: "settlement_on", type: "DATE" },
          { name: "sequence", type: "INTEGER", required: true },
          *%w[owner_id account_id asset_id].map { |n| { name: n, type: "TEXT", required: true, index: true } },
          { name: "quantity", type: "TEXT", required: true },
          { name: "unit", type: "TEXT", required: true },
          { name: "currency", type: "TEXT", required: true, pattern: "[A-Z]{3}" },
          *%w[price amount].map { |n| { name: n, type: "TEXT" } },
          { name: "fees", type: "TEXT", required: true },
          { name: "external_event_id", type: "TEXT" },
          { name: "transfer_id", type: "TEXT", index: true },
          { name: "reverses_event_id", type: "TEXT", index: true },
          { name: "correction_of", type: "TEXT" },
          { name: "sensitivity", type: "TEXT", required: true, enum: %w[normal private restricted] },
          { name: "metadata", type: "JSON", required: true }
        ]
      )
    end

    def observations
      StructuredDataset::Definition.from_h(
        slug: "finance_observations", name: "Financial Valuation Observations", kind: "finance_observations",
        purpose: "Append-only sourced prices, FX rates and portfolio valuations", sensitivity: "private",
        columns: [
          { name: "observation_key", type: "TEXT", required: true, unique: true },
          { name: "observation_type", type: "TEXT", required: true, enum: %w[price fx portfolio] },
          { name: "owner_id", type: "TEXT", required: true, index: true },
          { name: "asset_id", type: "TEXT", index: true },
          { name: "value", type: "TEXT", required: true },
          { name: "currency", type: "TEXT", required: true, pattern: "[A-Z]{3}" },
          { name: "base_currency", type: "TEXT", pattern: "[A-Z]{3}" },
          { name: "price_type", type: "TEXT", required: true, enum: %w[bid ask last appraisal market_estimate user_estimate confirmed_sale portfolio_close] },
          { name: "as_of", type: "DATETIME", required: true, index: true },
          { name: "retrieved_at", type: "DATETIME", required: true },
          { name: "quality", type: "TEXT", required: true, enum: %w[verified indicative estimated] },
          { name: "sensitivity", type: "TEXT", required: true, enum: %w[normal private restricted] },
          { name: "metadata", type: "JSON", required: true }
        ]
      )
    end

    def fetch(slug)
      { "finance_events" => events, "finance_observations" => observations }.fetch(slug)
    end
  end

  module Rows
    module_function

    def event(input, source:, booked_at:, index: 0)
      row = input.transform_keys(&:to_s)
      %w[quantity price amount fees].each { |key| Decimal.value(row[key]) if row[key] }
      %w[effective_at booked_at].each do |key|
        raise InvalidFinance, "financial timestamps require an explicit timezone" if row[key] && !row[key].match?(/(?:Z|[+-][0-9]{2}:[0-9]{2})\z/)
        row[key] = Time.iso8601(row[key]).utc.iso8601(6) if row[key]
      end
      # No implicit timestamp, quantity, currency or cost basis.
      base = { "booked_at" => booked_at, "sequence" => index, "fees" => "0", "metadata" => {}, "sensitivity" => "private" }.merge(row)
      key = base["deduplication_key"] || if base["external_event_id"]
        Digest::SHA256.hexdigest([source, base["account_id"], base["external_event_id"], base["operation"]].join("\0"))
      else
        Digest::SHA256.hexdigest(KnowledgeExtraction::Support.canonical_json(base.reject { |k, _| %w[booked_at event_id sequence].include?(k) }))
      end
      base["deduplication_key"] = key
      base["event_id"] ||= KnowledgeExtraction::Support.stable_id("finevent", key)
      Schemas.events.coerce_row(base)
    end

    def decoded(definition, row)
      definition.decode_row(definition.coerce_row(row))
    end

    def validate_event!(event, catalog)
      instrument = catalog.validate_event!(event)
      raise InvalidFinance, "asset contract changed since review/history" unless event.dig("metadata", "asset_contract_digest") == catalog.contract_digest(event["asset_id"])
      %w[quantity fees].each { |k| raise InvalidFinance, "#{k} cannot be negative" if Decimal.value(event[k]) < 0 }
      %w[price amount].each { |k| Decimal.value(event[k]) if event[k] }
      if event["price"] && Decimal.value(event["price"]) < 0 && instrument.data["asset_class"] != "future"
        raise InvalidFinance, "negative prices require a supported futures contract"
      end
      qty = Decimal.value(event["quantity"])
      op = event["operation"]
      trades = Projection::OPEN_LONG + Projection::CLOSE_LONG + %w[OPEN_SHORT CLOSE_SHORT OPTION_EXPIRATION OPTION_EXERCISE OPTION_ASSIGNMENT]
      raise InvalidFinance, "position operation requires positive quantity" if trades.include?(op) && qty <= 0
      if (Projection::OPEN_LONG + Projection::CLOSE_LONG + %w[OPEN_SHORT CLOSE_SHORT FUTURES_VARIATION_MARGIN VALUATION]).include?(op)
        unknown_opening = op == "OPENING_BALANCE" && event["metadata"]["confirmed"] == true && event["metadata"]["basis_status"] == "unknown"
        raise InvalidFinance, "price is required" unless event["price"] || unknown_opening
      end
      if op == "OPENING_BALANCE" && event["metadata"]["confirmed"] != true
        raise InvalidFinance, "opening balance requires explicit confirmation of known facts"
      end
      raise InvalidFinance, "cash assets use cash movement operations" if trades.include?(op) && instrument.data["asset_class"] == "cash"
      if event["settlement_on"] && event["settlement_on"] < event["effective_at"][0, 10]
        raise InvalidFinance, "settlement cannot precede trade date"
      end
      raise InvalidFinance, "unit must match the instrument" unless event["unit"] == instrument.data["unit"]
      if trades.include?(op) && event["amount"] && event["price"] && instrument.data["asset_class"] != "future"
        expected = qty * Decimal.value(event["price"]) * Decimal.value(instrument.data["multiplier"])
        raise InvalidFinance, "trade amount must equal gross quantity times price times multiplier" unless Decimal.value(event["amount"]) == expected
      end
      raise InvalidFinance, "reversal requires linkage" if op == "REVERSAL" && event["reverses_event_id"].to_s.empty?
    end

    def validate_observation!(row, catalog)
      owner = catalog.owner!(row.fetch("owner_id"))
      raise InvalidFinance, "restricted observation owner" if owner.data["sensitivity"] == "restricted" && row["sensitivity"] != "restricted"
      value = Decimal.value(row.fetch("value"))
      if row["observation_type"] == "price"
        instrument = catalog.asset(row.fetch("asset_id"))
        raise InvalidFinance, "negative price requires a future" if value < 0 && instrument.data["asset_class"] != "future"
        raise InvalidFinance, "price currency differs from instrument" unless instrument.data["currency"] == row["currency"]
        raise InvalidFinance, "observation owner does not own asset" unless Array(instrument.data["owner_ids"]).include?(row["owner_id"])
        raise InvalidFinance, "restricted price reference" if instrument.data["sensitivity"] == "restricted" && row["sensitivity"] != "restricted"
      elsif row["observation_type"] == "fx"
        Decimal.positive!(row.fetch("value"))
        raise InvalidFinance, "FX requires distinct base and quote currencies" unless row["base_currency"] && row["base_currency"] != row["currency"]
      elsif row["price_type"] != "portfolio_close"
        raise InvalidFinance, "portfolio values require portfolio_close price type"
      elsif value <= 0
        raise InvalidFinance, "performance portfolio observations require positive value"
      end
      raise InvalidFinance, "retrieval cannot precede observation" if Time.iso8601(row["retrieved_at"]) < Time.iso8601(row["as_of"])
    end
  end

  # Installed as a trusted Dataset Engine extension, never a second DB or writer.
  # Every administrative and proposal write path is subject to the same guard.
  module DatasetPolicy
    PROTECTED = %w[finance_events finance_observations].freeze

    def finance_catalog
      Catalog.new(vault_root: @vault_root)
    end

    def insert(reference, values, provenance = {})
      return super unless finance_dataset?(reference)
      append_finance(reference, [values], provenance)
    end

    def import_rows(reference, rows, provenance = {})
      return super unless finance_dataset?(reference)
      append_finance(reference, rows, provenance)
    end

    %i[replace update delete migrate evolve update_matching_ids migrate_medication_schedules].each do |method_name|
      define_method(method_name) do |reference, *args, **kwargs|
        raise StructuredDataset::InvalidRow, "financial history is append-only; propose a reversal/correction" if finance_dataset?(reference)
        kwargs.empty? ? super(reference, *args) : super(reference, *args, **kwargs)
      end
    end

    def append_finance(reference, rows, provenance)
      record, storage, definition = resolve(reference)
      finance_catalog.require_installed!
      unless definition.to_h == Schemas.fetch(definition.slug).to_h
        raise InvalidFinance, "financial Dataset schema differs from the trusted contract"
      end
      audit = audit_values(provenance)
      verify_finance_approval!(definition.slug, rows, audit)
      prepared = rows.map do |row|
        %w[quantity price amount fees value].each { |key| Decimal.value(row[key]) if row[key] }
        Rows.decoded(definition, row)
      end
      raise InvalidFinance, "empty finance batch" if prepared.empty?
      inserted = []
      activity_id = nil
      database.with_connection do |connection|
        database.transaction(connection) do
          existing = connection.execute("SELECT * FROM #{database.quote_identifier(storage.fetch('table_name'))}").map { |r| definition.decode_row(r) }
          key = definition.slug == "finance_events" ? "deduplication_key" : "observation_key"
          by_key = existing.to_h { |r| [r.fetch(key), r] }
          pending = []
          prepared.each do |row|
            if (prior = by_key[row[key]])
              compare = definition.columns.map(&:name) - %w[booked_at retrieved_at sequence event_id]
              unless compare.all? { |field| equivalent_financial_value?(field, prior[field], row[field]) }
                raise InvalidFinance, "duplicate financial key conflicts with recorded economics"
              end
              next
            end
            by_key[row[key]] = row
            pending << row
          end
          if definition.slug == "finance_events"
            current_catalog = finance_catalog.snapshot
            pending.each { |row| Rows.validate_event!(row, current_catalog) }
            Projection.new(events: existing + pending, catalog: current_catalog)
          else
            pending.each { |row| Rows.validate_observation!(row, finance_catalog) }
          end
          pending.each do |row|
            row_id = @id_generator.generate("row")
            # The Dataset store's unique intent_id is per row. The parent immutable
            # batch Intent remains in approval/audit; deterministic child receipts
            # bind every row to that parent without relaxing the unique index.
            child_audit = audit.merge("intent_id" => KnowledgeExtraction::Support.stable_id("intent", audit["intent_id"], row[key]))
            insert_row(connection, storage.fetch("table_name"), row_id, definition.coerce_row(row), child_audit, timestamp)
            inserted << row_id
          end
          unless inserted.empty?
            activity_id = database.record_activity(
              connection, dataset_id: record.id, action: "import", row_id: nil,
              actor_id: audit.fetch("created_by"), source: audit.fetch("source"),
              observation_id: audit["observation_id"], proposal_id: audit["proposal_id"],
              approval_id: audit["approval_id"], run_id: @run_id
            )
          end
        end
      end
      publish_change("import", record.id, nil, provenance: audit, row_count: inserted.length) unless inserted.empty?
      { "inserted" => inserted.length, "updated" => inserted.length, "row_ids" => inserted,
        "dataset_activity_id" => activity_id, "replayed" => inserted.empty? }
    rescue InvalidFinance => error
      raise StructuredDataset::InvalidRow, error.message
    end

    private

    def equivalent_financial_value?(field, first, second)
      if %w[quantity price amount fees value].include?(field) && !first.nil? && !second.nil?
        Decimal.value(first) == Decimal.value(second)
      else
        first == second
      end
    end

    def finance_dataset?(reference)
      return true if PROTECTED.include?(reference.to_s)
      _record, _storage, definition = resolve(reference)
      PROTECTED.include?(definition.slug) || PROTECTED.include?(definition.kind)
    rescue StructuredDataset::DatasetNotFound
      false
    end

    def verify_finance_approval!(slug, rows, audit)
      store = KnowledgeExtraction::ProposalStore.new(vault_root: @vault_root)
      proposal = store.load(audit.fetch("proposal_id"))
      receipt = store.approval(audit["proposal_id"])
      raise InvalidFinance, "financial writes require exact human approval" unless receipt &&
        receipt["approval_id"] == audit["approval_id"] && receipt["actor_id"] == audit["created_by"] &&
        receipt["proposal_fingerprint"] == store.proposal_fingerprint(proposal)
      match = proposal.fetch("planned_intents").find do |planned|
        payload = planned.fetch("intent").fetch("params")
        provenance_matches = %w[source observation_id evidence_id source_uri source_filename].all? do |field|
          payload[field] == audit[field]
        end
        planned.dig("intent", "type") == "AppendFinanceRows" && payload["intent_id"] == audit["intent_id"] &&
          provenance_matches &&
          payload["dataset"] == slug && receipt["approved_intent_ids"].include?(planned["planned_intent_id"]) &&
          KnowledgeExtraction::Support.canonical_json(payload["rows"]) == KnowledgeExtraction::Support.canonical_json(rows)
      end
      raise InvalidFinance, "financial rows differ from the exact approved batch" unless match
    rescue KeyError, KnowledgeExtraction::Error
      raise InvalidFinance, "financial writes require an existing exact-approved proposal"
    end


  end
end

module KnowledgeGraph
  class AppendFinanceRows < DatasetIntent
    field :dataset
    field :rows
    field :evidence_id, default: nil
    field :source_uri, default: nil
    field :source_filename, default: nil
  end
end
