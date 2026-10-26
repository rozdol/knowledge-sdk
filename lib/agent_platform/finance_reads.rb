# frozen_string_literal: true

module AgentPlatform
  # Typed presentation of the existing Finance accounting service. All Dataset
  # reads use a nonmigrating Reader, including ordinary (non-dashboard) callers.
  class FinanceReads < ReadViews
    OPERATIONS = %w[scopes net_worth positions liabilities transactions pnl].freeze
    TRANSACTION_FIELDS = %w[row_id event_id operation effective_at booked_at settlement_on sequence
      owner_id account_id asset_id quantity unit currency price amount fees reverses_event_id correction_of].freeze
    REPORT_FIELDS = %w[status owner_id account_id asset_id as_of from to currency net_worth known_subtotal
      components kind value reporting_value fx rate base_currency quote_currency quality freshness
      valuation_status coverage limitations execution_authorized positions cost_basis_policy quantity cost_basis
      average_entry_price basis_status lots opening_event_id price opened_at market_value unrealized_pnl
      valuation retrieved_at observed_price split_adjustment_events price_type executable_quote fx_rate
      asset_class instrument accounting_method notional_value debts direction counterparty_id counterparty
      outstanding_principal accrued_interest original_principal overdue_principal due_dates interest_method
      accounting_basis totals realized variation_margin income expense fee realized_pnl fees unrealized_change
      net_pnl fx_contribution opening_positions closing_positions net_external_cash_flows event_id effective_at
      category amount months unit multiplier].freeze

    class Rows
      def initialize(data)
        @data = data
      end

      def query(dataset, limit:, offset:, **_options)
        @data.fetch(dataset).slice(offset, limit) || []
      end
    end

    def self.register(registry, services)
      OPERATIONS.each do |operation|
        registry.register("kg.finance.#{operation}") do |arguments, context|
          payload = new(services, context).call(operation, arguments)
          HandlerResult.new(payload: payload, why: "Read policy-visible Finance history through an injected nonmigrating Reader; no execution authority.")
        end
      end
    end

    def call(operation, arguments)
      @args = arguments
      return unavailable("source_bound_reached") unless within_read_budget?
      return unavailable("finance_plugin_unavailable") unless KnowledgeFinance::Catalog.new(vault_root: @services.vault_root).installed?
      build_catalog
      return scopes if operation == "scopes"
      validate_scope!
      validate_window!(operation)
      registrations = %w[finance_events finance_observations].each_with_object({}) do |slug, all|
        all[slug] = catalog.records("dataset").find { |record| record["dataset_slug"] == slug }
      end
      return unavailable("finance_history_unavailable") unless registrations["finance_events"]
      reader = @services.activity_reader(@context)
      reader.with_consistent_read do
        @rows = {}
        %w[finance_events finance_observations].each do |slug|
          registration = registrations[slug]
          if !registration
            return unavailable("finance_history_unavailable") if slug == "finance_events"
            @rows[slug] = []
            next
          end
          description = reader.describe(registration.id)
          expected = KnowledgeFinance::Schemas.fetch(slug).columns.map(&:to_h)
          return unavailable("finance_schema_unsupported") unless description["columns"] == expected
          @rows[slug] = load_rows(reader, registration.id)
        end
        @service = KnowledgeFinance::Service.new(vault_root: @services.vault_root,
          dataset_engine: Rows.new(@rows), catalog: catalog, clock: @services.clock,
          include_restricted: restricted?)
        # Replay the complete owner history even for a transaction display. This
        # refuses a broken/partly visible transfer or reversal rather than totals
        # based on an arbitrarily truncated accounting input.
        @book = @service.projection(owner_id: @args.fetch("owner_id"), as_of: @args["as_of"] || @args["to"])
        send(operation)
      end
    rescue StructuredDataset::StorageUnavailable => error
      unavailable(error.code)
    rescue StructuredDataset::DatasetNotFound
      unavailable("finance_history_unavailable")
    rescue KnowledgeFinance::MissingHistory
      unavailable("finance_history_incomplete")
    rescue KnowledgeFinance::InvalidFinance, StructuredDataset::Error
      unavailable("finance_history_invalid")
    rescue ArgumentError, TypeError
      raise InvalidArguments, "invalid typed Finance arguments"
    end

    private

    attr_reader :catalog

    def restricted?
      %w[finance:restricted graph:restricted dataset:restricted].all? { |grant| @agent.permits?(grant) }
    end

    def references(value)
      case value
      when Hash then value.values.flat_map { |item| references(item) }
      when Array then value.flat_map { |item| references(item) }
      when String
        # Operational/event/Evidence IDs are not graph identities.
        value.scan(/[a-z][a-z0-9-]*_[0-9A-HJKMNP-TV-Z]{26}/).select { |id| @prefixes.include?(id.split("_", 2).first) } +
          value.scan(WIKI).flatten.map { |link| raw_snapshot.resolve_link("[[#{link}]]") || "missing" }
      else []
      end
    end

    def build_catalog
      registry = KnowledgeGraph::SchemaRegistry.new(vault_root: @services.vault_root)
      @prefixes = registry.keys.map { |key| registry.fetch(key).id_prefix }
      records = raw_snapshot.records.select do |record|
        record["sensitivity"] != "restricted" || restricted?
      end
      loop do
        ids = records.map(&:id)
        selected = records.reject do |record|
          next false unless record.type.start_with?("financial_") || record.type == "dataset"
          data = record.data.dup
          %w[details_json identifiers_json].each { |key| data[key] = JSON.parse(data[key]) if data[key] }
          references(data).any? { |id| !ids.include?(id) }
        end
        break if selected.length == records.length
        records = selected
      end
      @catalog = KnowledgeFinance::SnapshotCatalog.new(KnowledgeIntelligence::GraphSnapshot.new(records))
    rescue JSON::ParserError
      raise KnowledgeFinance::InvalidFinance, "invalid financial catalog"
    end

    def scopes
      accounts = catalog.records("financial_account")
      assets = catalog.records("financial_asset")
      ids = (accounts + assets).flat_map { |record| Array(record["owner_ids"]) } + catalog.records("financial_owner").map(&:id)
      owners = ids.uniq.sort.map { |id| catalog.owner!(id) }
      return unavailable("scope_bound_reached") if [owners, accounts, assets].any? { |items| items.length > 1000 }
      data = { "owners" => owners.map { |record| scope_item(record) },
        "accounts" => accounts.sort_by(&:id).map { |record| scope_item(record) },
        "assets" => assets.sort_by(&:id).map { |record| scope_item(record) } }
      result(data, dependencies: data, empty: owners.empty?)
    end

    def scope_item(record)
      item = { "id" => record.id, "name" => text(record.name), "type" => record.type }
      %w[owner_ids currency unit multiplier asset_class owner_kind].each { |key| item[key] = record[key] if record[key] }
      item
    end

    def validate_scope!
      owner = @args.fetch("owner_id")
      begin
        catalog.owner!(owner)
        %w[account_id asset_id].each do |key|
          next unless @args[key]
          record = catalog.resolve(@args[key], key == "account_id" ? "financial_account" : "financial_asset")
          raise KnowledgeFinance::InvalidFinance, "unrelated scope" unless Array(record["owner_ids"]).include?(owner)
        end
      rescue KnowledgeFinance::InvalidFinance
        raise PolicyDenied, "record not found"
      end
    end

    def finance_time(value, end_of_day: true)
      raise InvalidArguments, "Finance time requires a date or explicit offset" unless value.to_s.match?(/\A\d{4}-\d\d-\d\d(?:T\d\d:\d\d:\d\d(?:\.\d{1,6})?(?:Z|[+-]\d\d:\d\d))?\z/)
      Date.iso8601(value[0, 10])
      text = value.length == 10 ? "#{value}T#{end_of_day ? '23:59:59.999999' : '00:00:00'}Z" : value
      Time.iso8601(text).utc
    end

    def validate_window!(operation)
      @args = @args.dup
      @args["as_of"] ||= @services.clock.call.utc.to_date.iso8601 if %w[positions net_worth liabilities].include?(operation)
      finance_time(@args["as_of"]) if @args["as_of"]
      if %w[transactions pnl].include?(operation)
        raise InvalidArguments, "both Finance boundaries are required" if !!@args["from"] != !!@args["to"]
        today = @args["as_of"] ? finance_time(@args["as_of"]).to_date : @services.clock.call.utc.to_date
        @args["to"] ||= today.iso8601
        @args["from"] ||= (operation == "pnl" ? Date.new(today.year, today.month, 1) : today - 29).iso8601
        start, finish = finance_time(@args["from"], end_of_day: false), finance_time(@args["to"])
        raise InvalidArguments, "invalid Finance window" unless finish >= start && finish.to_date - start.to_date <= 366
        if @args["period"] == "monthly" && [@args["from"], @args["to"]].any? { |value| value.length != 10 }
          raise InvalidArguments, "monthly reports require inclusive dates"
        end
        raise InvalidArguments, "report exceeds as_of" if @args["as_of"] && finish > finance_time(@args["as_of"])
      end
    end

    def load_rows(reader, id)
      rows, offset = [], 0
      loop do
        page = reader.query(id, order: "row_id:asc", limit: 10_000, offset: offset)
        rows.concat(page.select do |row|
          row["owner_id"] == @args["owner_id"] && (row["sensitivity"] != "restricted" || restricted?) &&
            references(row.reject { |key, _| StructuredDataset::Definition::RESERVED_COLUMNS.include?(key) }).all? do |ref|
              begin
                catalog.resolve(ref)
                true
              rescue KnowledgeFinance::InvalidFinance
                false
              end
            end
        end)
        break if page.length < 10_000
        offset += 10_000
        raise StructuredDataset::StorageUnavailable, "finance_replay_bound_reached" if offset >= 100_000
      end
      rows
    end

    def selected?(item)
      %w[account_id asset_id].all? { |key| !@args[key] || item[key] == @args[key] }
    end

    def project(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, item), result|
          item = item.select { |flow| selected?(flow) } if key == "net_external_cash_flows"
          result[key] = project(item) if REPORT_FIELDS.include?(key)
        end
      when Array then value.map { |item| project(item) }
      when String then value[0, 1000]
      else value
      end
    end

    def dependencies
      records = catalog.records("financial_asset") + catalog.records("financial_account")
      ids = records.flat_map { |record| references(record.data) } + [@args["owner_id"]]
      [@rows, records.map(&:data), ids.compact.uniq.sort.map { |id| catalog.resolve(id).data }]
    end

    def report(value)
      data = project(value)
      limitations = []
      limitations << "finance_report_incomplete" if value["status"] == "partial"
      limitations << "missing_valuation_or_fx" if data.key?("net_worth") && data["net_worth"].nil?
      positions = Array(data["positions"]) + Array(data["opening_positions"]) + Array(data["closing_positions"])
      limitations << "missing_basis_or_mark" if positions.any? { |item| !item["cost_basis"] || !item["market_value"] }
      limitations << "stale_or_estimated_valuation" if JSON.generate(data).match?(/"(?:freshness|quality)":"(?:stale|estimated)"/)
      response = result(data, dependencies: dependencies, limitations: limitations.uniq, evidence: evidence)
      response["status"] = "partial" if value["status"] == "partial"
      response
    end

    def evidence
      @rows.fetch("finance_events").select { |row| selected?(row) }.map { |row| row["evidence_id"] }.uniq.compact.grep(/\Aevidence_[0-9A-HJKMNP-TV-Z]{26}\z/).first(20).map do |id|
        { "record_id" => @args.fetch("owner_id"), "evidence_id" => id, "role" => "finance_source" }
      end
    end

    def positions
      value = @service.holdings(owner_id: @args["owner_id"], asset_id: @args["asset_id"], as_of: @args["as_of"])
      items = value.fetch("positions").select { |item| selected?(item) }.map do |item|
        asset = catalog.asset(item["asset_id"])
        project(item).merge("unit" => asset["unit"], "multiplier" => asset["multiplier"])
      end.sort_by { |item| item.values_at("account_id", "asset_id", "currency") }
      limits = []
      limits << "missing_basis_or_mark" if items.any? { |item| !item["cost_basis"] || !item["market_value"] }
      limits << "stale_or_estimated_valuation" if items.any? { |item| item.dig("valuation", "freshness") == "stale" || item.dig("valuation", "quality") == "estimated" }
      response = list(items, items.map { |item| item.values_at("account_id", "asset_id", "currency") }, limitations: limits)
      response["source_version"] = Digest::SHA256.hexdigest(Value.canonical_json([dependencies, items]))
      response["evidence"] = evidence
      response["data"].merge!("owner_id" => @args["owner_id"], "as_of" => value["as_of"], "coverage" => value["coverage"], "execution_authorized" => false)
      response
    end

    def net_worth
      report(@service.networth(owner_id: @args["owner_id"], as_of: @args["as_of"], currency: @args.fetch("currency", "EUR")))
    end

    def liabilities
      report(@service.debt_report(owner_id: @args["owner_id"], as_of: @args["as_of"], direction: @args["direction"]))
    end

    def transactions
      rows = @book.events.select do |row|
        selected?(row) && finance_time(row["effective_at"]) >= finance_time(@args["from"], end_of_day: false) &&
          finance_time(row["effective_at"]) <= finance_time(@args["to"])
      end.sort_by { |row| [row["effective_at"], row["sequence"], row["event_id"]] }.reverse
      items = rows.map { |row| row.select { |key, _| TRANSACTION_FIELDS.include?(key) } }
      response = list(items, rows.map { |row| row.values_at("effective_at", "sequence", "event_id") })
      response["source_version"] = Digest::SHA256.hexdigest(Value.canonical_json(dependencies))
      response["evidence"] = evidence
      response
    end

    def pnl
      method = @args["period"] == "monthly" ? :monthly : :pnl
      report(@service.send(method, owner_id: @args["owner_id"], account_id: @args["account_id"], asset_id: @args["asset_id"], from: @args["from"], to: @args["to"]))
    end
  end
end
