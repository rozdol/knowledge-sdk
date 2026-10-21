# frozen_string_literal: true

require "csv"

module KnowledgeFinance
  class Proposals
    attr_reader :service, :store

    def initialize(vault_root:, dataset_engine: nil, proposal_store: nil, clock: nil, event_bus: nil)
      @clock = clock || -> { Time.now }
      @service = Service.new(vault_root: vault_root, dataset_engine: dataset_engine, clock: @clock, include_restricted: true)
      @store = proposal_store || KnowledgeExtraction::ProposalStore.new(vault_root: vault_root, clock: @clock)
      @factory = KnowledgeExtraction::ReviewProposalBuilder.new(
        vault_root: vault_root, proposal_store: @store, clock: @clock, event_bus: event_bus, domain: "finance"
      )
    end

    def document(arguments)
      KnowledgeExtraction::SourceDocument.new(
        source_type: arguments.fetch("source_type", "text"), content: arguments.fetch("content"),
        captured_at: arguments["captured_at"], external_id: arguments["external_id"],
        source_uri: arguments["source_uri"], title: arguments["title"],
        metadata: { "sensitivity" => arguments.fetch("sensitivity", "private"),
                    "conversation_id" => arguments["conversation_id"], "sender" => arguments["sender"] }
      )
    end

    def rows(dataset:, rows:, arguments:)
      service.catalog.require_installed!
      raise InvalidFinance, "finance batch requires 1..10000 row objects" unless rows.is_a?(Array) && rows.length.between?(1, 10_000) && rows.all? { |row| row.is_a?(Hash) }
      arguments = arguments.merge("sensitivity" => "restricted") if rows.any? { |r| r["sensitivity"] == "restricted" || r[:sensitivity] == "restricted" }
      doc = document(arguments)
      source = arguments.fetch("origin_source", doc.source_type)
      definition = Schemas.fetch(dataset)
      prepared = rows.each_with_index.map do |row, index|
        input = row.transform_keys(&:to_s)
        input["sensitivity"] = "restricted" if arguments["sensitivity"] == "restricted"
        if dataset == "finance_events"
          Rows.decoded(definition, Rows.event(input, source: source, booked_at: doc.captured_at&.iso8601(6) || @clock.call.iso8601(6), index: index))
        else
          Decimal.value(input.fetch("value"))
          %w[as_of retrieved_at].each { |key| input[key] = Time.iso8601(input.fetch(key)).utc.iso8601(6) }
          Rows.decoded(definition, input)
        end
      end
      if dataset == "finance_events"
        current_catalog = service.catalog.snapshot
        prepared.each do |row|
          row["metadata"]["asset_contract_digest"] = current_catalog.contract_digest(row["asset_id"])
        end
        prepared.each { |row| Rows.validate_event!(row, current_catalog) }
        existing = service.rows(dataset)
        fresh = prepared.reject { |row| existing.any? { |e| e["deduplication_key"] == row["deduplication_key"] } }
        Projection.new(events: existing + fresh, catalog: current_catalog)
      else
        prepared.each { |row| Rows.validate_observation!(row, service.catalog) }
      end
      digest = KnowledgeExtraction::Support.canonical_json(prepared)
      intent_id = KnowledgeExtraction::Support.stable_id("intent", doc.source_id, dataset, digest)
      lifecycle = StructuredDataset::AutonomousRegistry.new(vault_root: service.catalog.root, engine: service.engine, clock: @clock).plan(
        dataset: dataset, values: prepared.first || {}, schema: definition,
        dataset_id: KnowledgeExtraction::Support.stable_id("dataset", service.catalog.root, dataset), source: source
      )
      planned = []
      if lifecycle.prerequisite?
        planned << { intent: lifecycle.intent, planned_intent_id: KnowledgeExtraction::Support.stable_id("planned", intent_id, "lifecycle") }
      end
      evidence_id = @factory.evidence_id(doc, role: "finance")
      intent = KnowledgeGraph::AppendFinanceRows.new(
        dataset: dataset, rows: prepared, source: source, observation_id: arguments["observation_id"] || doc.source_id,
        intent_id: intent_id, evidence_id: evidence_id, source_uri: doc.source_uri, source_filename: doc.title
      )
      planned << { intent: intent, planned_intent_id: KnowledgeExtraction::Support.stable_id("planned", intent_id),
                   dependencies: planned.map { |p| p[:planned_intent_id] },
                   risk: prepared.any? { |r| r["operation"] == "REVERSAL" } ? "high" : "medium" }
      persist(doc, planned, "Review #{prepared.length} immutable #{dataset} row(s).", {
        "dataset" => dataset, "event_count" => prepared.length, "lifecycle" => lifecycle.to_h,
        "accounting_basis" => "fifo", "intent" => "finance.record_transaction"
      })
    end

    def register(kind:, attributes:, arguments:)
      service.catalog.require_installed!
      type = { "owner" => "financial_owner", "account" => "financial_account", "asset" => "financial_asset" }.fetch(kind)
      data = attributes.transform_keys(&:to_s)
      data["sensitivity"] ||= arguments.fetch("sensitivity", "private")
      data["provenance"] ||= arguments.fetch("origin_source", "manual")
      data["identifiers_json"] = JSON.generate(KnowledgeFinance.identifiers.validate(data.delete("identifiers") || [])) unless data.key?("identifiers_json")
      data["details_json"] = JSON.generate(data.delete("details") || {}) unless data.key?("details_json")
      data["identification_status"] ||= "user_identified"
      doc = document(arguments)
      data["id"] ||= KnowledgeExtraction::Support.stable_id(type.delete("_"), doc.source_id, KnowledgeExtraction::Support.canonical_json(data))
      service.catalog.validate_record!(type, data)
      intent = KnowledgeGraph::CreateEntity.new(entity_type: type, attributes: data,
        intent_id: KnowledgeExtraction::Support.stable_id("intent", doc.source_id, type, data["id"]))
      persist(doc, [{ intent: intent, planned_intent_id: KnowledgeExtraction::Support.stable_id("planned", intent.intent_id) }],
              "Review registration of #{kind}: #{data.fetch('name')}", { "intent" => "finance.register_#{kind}", "entity_id" => data["id"] })
    end

    def persist(doc, planned, summary, metadata)
      proposal, items = @factory.persist(document: doc, planned_intents: planned, summary: summary,
                                         model_metadata: metadata, confidence: 1.0)
      { "status" => "awaiting_approval", "intent" => metadata.fetch("intent", "finance.record_transaction"),
        "proposal_id" => proposal.fetch("proposal_id"), "planned_intent_count" => items.length,
        "approval_required" => true, "executable" => false, "execution_authorized" => false,
        "confirmation" => "#{summary} Nothing is recorded until exact human approval and successful submission.",
        "details" => metadata }
    end
  end

  class Importer
    def initialize(proposals:)
      @proposals = proposals
    end

    def propose(path:, dataset: "finance_events", source: "manual-statement", owner_id: nil, account_id: nil, timezone_offset: nil)
      file = Pathname.new(path).expand_path
      raise InvalidFinance, "financial statement must be a local file up to 10 MB" unless file.file? && file.size <= 10_000_000
      rows = case file.extname.downcase
             when ".csv" then CSV.read(file.to_s, headers: true).map(&:to_h)
             when ".json"
               payload = JSON.parse(file.read, decimal_class: BigDecimal)
               raise InvalidFinance, "JSON financial values must be quoted decimal strings" if contains_decimal?(payload)
               payload.is_a?(Hash) ? payload.fetch("rows") : payload
             when ".xlsx" then StructuredDataset::Xlsx.read(file)
             when ".xml"
               raise InvalidFinance, "Flex import requires explicit owner and account IDs" unless owner_id && account_id && dataset == "finance_events"
               source = "ibkr-flex"
               FlexStatement.new(catalog: @proposals.service.catalog, owner_id: owner_id, account_id: account_id, timezone_offset: timezone_offset).parse(file.read)
             else raise InvalidFinance, "supported statement formats: normalized CSV, JSON, XLSX"
             end
      raise InvalidFinance, "statement requires 1..10000 normalized rows" unless rows.is_a?(Array) && rows.length.between?(1, 10_000)
      # Source evidence retains the complete normalized rendition, with the
      # original file URI. No imported column can provide approval provenance.
      allowed = Schemas.fetch(dataset).columns.map(&:name)
      rows = rows.map do |raw|
        row = raw.reject { |_, v| v.nil? || v == "" }.transform_keys(&:to_s)
        raise InvalidFinance, "unknown statement columns" unless (row.keys - allowed).empty?
        row["metadata"] = JSON.parse(row["metadata"]) if row["metadata"].is_a?(String)
        row
      end
      @proposals.rows(dataset: dataset, rows: rows, arguments: {
        "source_type" => "text", "content" => file.extname.downcase == ".xml" ? file.read : JSON.pretty_generate(rows), "source_uri" => file.to_s,
        "title" => file.basename.to_s, "origin_source" => source
      })
    rescue CSV::MalformedCSVError, JSON::ParserError, KeyError => error
      raise InvalidFinance, "invalid normalized financial statement: #{error.class.name}"
    end

    def reconcile(snapshots:, owner_id:, as_of:)
      service = @proposals.service
      book = service.projection(owner_id: owner_id, as_of: as_of)
      discrepancies = snapshots.map do |row|
        row = row.transform_keys(&:to_s)
        service.catalog.validate_event!({ "owner_id" => owner_id, "account_id" => row.fetch("account_id"), "asset_id" => row.fetch("asset_id"),
                                         "currency" => row.fetch("currency"), "sensitivity" => row.fetch("sensitivity", "private") })
        position = book.positions.find { |p| p["account_id"] == row["account_id"] && p["asset_id"] == row["asset_id"] && p["currency"] == row["currency"] }
        quantity = position ? Decimal.value(position["quantity"]) : BigDecimal("0")
        difference = Decimal.value(row.fetch("quantity")) - quantity
        row.merge("ledger_quantity" => Decimal.text(quantity), "difference" => Decimal.text(difference),
                  "status" => difference.zero? ? "matched" : "unresolved_history")
      end
      { "status" => discrepancies.all? { |r| r["status"] == "matched" } ? "reconciled" : "unresolved",
        "as_of" => as_of, "rows" => discrepancies, "history_created" => false, "execution_authorized" => false }
    end

    private

    def contains_decimal?(value)
      case value
      when Hash then value.values.any? { |v| contains_decimal?(v) }
      when Array then value.any? { |v| contains_decimal?(v) }
      else value.is_a?(BigDecimal) || value.is_a?(Float)
      end
    end
  end
end
