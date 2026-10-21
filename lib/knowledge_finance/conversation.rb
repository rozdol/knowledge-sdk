# frozen_string_literal: true

require "tempfile"

module KnowledgeFinance
  class Classifier
    READ = /(?:сколько\s+у\s+меня|какие\s+акци|кто\s+мне\s+должен|кому.*я\s+должен|стоимость.*актив|чист[[:alpha:]]+\s+капитал|прибыл|доходност|заработал|динамика.*p&l|что.*продать|how\s+many.*(?:shares|stocks)|holdings|net\s*worth|who\s+owes|whom.*owe|who\s+do\s+i\s+owe|\b(?:profit|p&l|returns|performance)\b|investment.*(?:return|profit|p&l)|monthly.*p&l|portfolio\s+performance|what.*sell|πόσες.*μετοχ|ποιος.*χρωστά|σε\s+ποιον.*χρωστά|καθαρή\s+περιουσία|τι.*πουλήσω)/i.freeze
    MUTATION = /(?:купил[аи]?|продал[аи]?|закрыл[аи]?.*позиц|открыл[аи]?.*позиц|(?:должен|должна)\s+мне|мне\s+долж(?:ен|на)|я\s+должен|у\s+меня\s+есть\s+(?:квартир|дом|машин|земл)|\b(?:bought|sold|opened|closed)\b.*(?:shares?|stocks?|position|contracts?)|\bowes\s+me\b|\bi\s+owe\b|\bi\s+own\s+(?:an?\s+)?(?:apartment|property|car)|αγόρασα|πούλησα|έκλεισα.*θέση|μου\s+χρωστά)/i.freeze
    DETAILS = /(?:\Afinance\s+details\s*:|\b(?:owner_id|account_id|asset_id|opening_date|opening_price|quantity|effective_at|price|amount|unit|currency|confirmed|basis_status|operation|creditor_id|debtor_id|asset_class|name|multiplier|owner_ids|owner_kind|provenance)\s*=)/i.freeze

    def self.parse(text, context = {})
      return nil if KnowledgeCapture::IntentClassifierPlugin.explicit_capture?(text)
      intent = if text.lstrip.start_with?('{"finance"') || text.match?(/\A\s*\{\s*"finance"\s*:/)
                 "finance.record_transaction"
               elsif DETAILS.match?(text) || (context["finance_pending"] && text.match?(/(?:открыл|opened|opening|количеств|quantity|сч[её]т)/i))
                 "finance.record_transaction"
               elsif READ.match?(text)
                 if text.match?(/что.*продать|what.*sell|τι.*πουλήσω/i) then "finance.plan_liquidity"
                 elsif text.match?(/net\s*worth|стоимость.*актив|чист[[:alpha:]]+\s+капитал|καθαρή\s+περιουσία/i) then "finance.analyze_portfolio"
                 elsif text.match?(/должен|owed|owes|\bowe\b|χρωστά/i) then "finance.query_debts"
                 elsif text.match?(/прибыл|заработал|доходност|p&l|return|profit|performance/i) then "finance.query_performance"
                 else "finance.query_holdings"
                 end
               elsif MUTATION.match?(text)
                 if text.match?(/закрыл|closed|έκλεισα/i) then "finance.close_position"
                 elsif text.match?(/купил|открыл|bought|opened|αγόρασα/i) then "finance.open_position"
                 elsif text.match?(/должен|должна|owes|\bowe\b|χρωστά/i) then "finance.register_liability"
                 elsif text.match?(/продал|sold|πούλησα/i) then "finance.close_position"
                 else "finance.register_asset"
                 end
               end
      return nil unless intent
      read = %w[finance.query_holdings finance.query_debts finance.query_performance finance.analyze_portfolio finance.plan_liquidity].include?(intent)
      { "intent" => intent, "confidence" => 1.0, "route" => read ? "search" : "dataset",
        "explanation" => "trusted finance domain recognizer; no execution authority", "slots" => {} }
    end
  end

  # Derived clarification state, scoped to Vault + transport + sender + chat.
  # It contains source data, never approval or executable policy.
  class ConversationState
    def initialize(root)
      @root = Pathname.new(root)
    end

    def path(arguments)
      return nil if arguments["conversation_id"].to_s.empty? || arguments["sender"].to_s.empty?
      key = Digest::SHA256.hexdigest([arguments["_finance_actor"], arguments["origin_source"], arguments["conversation_id"], arguments["sender"]].join("\0"))
      @root.join(KnowledgeSDK::RUNTIME_PATH, "finance/clarifications", "#{key}.json")
    end

    def load(arguments)
      file = path(arguments)
      file && file.file? ? JSON.parse(file.read) : nil
    rescue JSON::ParserError
      raise InvalidFinance, "invalid local finance clarification state"
    end

    def save(arguments, payload)
      file = path(arguments)
      return unless file
      FileUtils.mkdir_p(file.dirname)
      Tempfile.create([".finance", ".tmp"], file.dirname.to_s) do |tmp|
        tmp.chmod(0600)
        tmp.write(JSON.generate(payload)); tmp.flush; tmp.fsync
        File.rename(tmp.path, file)
      end
    end
  end

  class Conversation
    def initialize(vault_root:, proposal_store: nil, dataset_engine: nil, event_bus: nil, clock: nil, include_restricted: false)
      @clock = clock || -> { Time.now }
      @service = Service.new(vault_root: vault_root, dataset_engine: dataset_engine, clock: @clock, include_restricted: include_restricted)
      @proposals = Proposals.new(vault_root: vault_root, proposal_store: proposal_store, dataset_engine: @service.engine, clock: @clock, event_bus: event_bus)
      @state = ConversationState.new(vault_root)
    end

    def read(arguments)
      text = arguments.fetch("content")
      fields = parse_fields(text)
      kind = Classifier.parse(text)&.fetch("intent", nil)
      owner = @service.owner_scope(fields["owner_id"])
      return @service.scope_clarification unless owner
      window = Window.new(text, @clock.call.to_date, fields)
      assets = matching_assets(text, fields)
      case kind
      when "finance.query_debts"
        direction = text.match?(/кто\s+мне|who\s+owes|ποιος/i) ? "receivable" : "payable"
        @service.debt_report(owner_id: owner, as_of: fields["as_of"], direction: direction)
      when "finance.analyze_portfolio"
        @service.networth(owner_id: owner, as_of: fields["as_of"], currency: fields.fetch("reporting_currency", "EUR"))
      when "finance.plan_liquidity"
        amount = fields["target"] || text[/([0-9][0-9, .]*[0-9]|[0-9]+)\s*(?:EUR|евро|ευρώ)/i, 1]&.delete(" ,")
        return clarify(kind, ["target", "currency"], text, fields, arguments) unless amount
        @service.liquidity(owner_id: owner, target: amount, currency: fields.fetch("currency", "EUR"), deadline: fields["deadline"])
      when "finance.query_performance"
        if assets.length > 1
          return clarify(kind, ["instrument_identity"], text, fields, arguments, candidates: assets)
        end
        specific_options = text[/опционах\s+([A-Z][A-Z0-9._-]*)\b/i, 1]
        return clarify(kind, ["instrument_identity"], text, fields, arguments) if specific_options && assets.empty?
        asset_ids = if specific_options && assets.length == 1 && assets.first.data["asset_class"] == "future"
                      @service.catalog.records("financial_asset").select do |asset|
                        %w[option futures_option].include?(asset.data["asset_class"]) &&
                          @service.catalog.details(asset)["underlying_id"] == assets.first.id && @service.visible?("asset_id" => asset.id)
                      end.map(&:id)
                    elsif assets.length == 1 then [assets.first.id]
                    end
        if text.match?(/доходност|\breturns?\b|performance/i) && !text.match?(/прибыл|profit|p&l/i)
          if asset_ids
            return { "status" => "unavailable", "execution_authorized" => false,
                     "limitations" => ["Instrument percentage returns require separately attributed valuations and cash flows."] }
          end
          @service.performance(owner_id: owner, from: window.from, to: window.to, currency: fields.fetch("reporting_currency", "EUR"))
        elsif text.match?(/по\s+месяцам|monthly|по\s+месяц/i)
          @service.monthly(owner_id: owner, from: window.from, to: window.to, asset_ids: asset_ids)
        else
          report = @service.pnl(owner_id: owner, from: window.from, to: window.to, asset_ids: asset_ids)
          if text.match?(/наибольш|максималь|most|highest|best/i)
            report["instrument_breakdown"] = @service.catalog.records("financial_asset").select { |a| @service.visible?("asset_id" => a.id) }.map do |asset|
              { "asset_id" => asset.id, "instrument" => asset.data["name"],
                "totals" => @service.pnl(owner_id: owner, from: window.from, to: window.to, asset_id: asset.id)["totals"] }
            end
            report["ranking"] = report["instrument_breakdown"].flat_map do |asset|
              asset["totals"].select { |t| t["realized"] }.map { |t| asset.slice("asset_id", "instrument").merge(t) }
            end.group_by { |r| r["currency"] }.transform_values { |group| group.sort_by { |r| -Decimal.value(r["realized"]) } }
          end
          report
        end
      else
        return clarify("finance.query_holdings", ["instrument_identity"], text, fields, arguments, candidates: assets) if assets.length != 1
        @service.holdings(owner_id: owner, asset_id: assets.first.id, as_of: window.historical ? window.to : fields["as_of"])
      end
    end

    def propose(arguments)
      @service.catalog.require_installed!
      text = arguments.fetch("content")
      if text.lstrip.start_with?("{")
        payload = JSON.parse(text, decimal_class: BigDecimal).fetch("finance")
        raise InvalidFinance, "finance payload must be an object" unless payload.is_a?(Hash)
        if payload["kind"]
          return @proposals.register(kind: payload.fetch("kind"), attributes: payload.fetch("attributes"), arguments: arguments)
        end
        return @proposals.rows(dataset: payload.fetch("dataset", "finance_events"), rows: payload.fetch("rows"), arguments: arguments)
      end
      pending = @state.load(arguments)
      fields = parse_fields(text)
      use_pending = pending && pending["status"] == "clarification_required" && Classifier::DETAILS.match?(text)
      if use_pending && pending["sensitivity"] == "restricted"
        raise InvalidFinance, "restricted clarification requires restricted finance permissions" unless @service.restricted_reads?
        arguments = arguments.merge("sensitivity" => "restricted")
      end
      original = use_pending ? pending.fetch("original_text") : text
      fields = pending.fetch("fields").merge(fields) if use_pending
      classification = Classifier.parse(original) || { "intent" => "finance.record_transaction" }
      intent = classification.fetch("intent")
      fields["operation"] ||= if original.match?(/закрыл|closed|продал|sold|έκλεισα|πούλησα/i) then "CLOSE_LONG"
                              elsif original.match?(/купил|bought|αγόρασα|открыл|opened/i) then "BUY"
                              end
      assets = matching_assets(original, fields)
      fields["asset_id"] ||= assets.first.id if assets.length == 1
      owner = @service.owner_scope(fields["owner_id"])
      fields["owner_id"] ||= owner if owner
      accounts = @service.catalog.records("financial_account").select do |a|
        @service.visible?("account_id" => a.id) && Array(a.data["owner_ids"]).include?(fields["owner_id"])
      end
      fields["account_id"] ||= accounts.first.id if accounts.length == 1
      if fields["asset_id"]
        asset = @service.catalog.asset(fields["asset_id"])
        fields["currency"] ||= asset.data["currency"]
        fields["unit"] ||= asset.data["unit"]
      end
      fields["price"] ||= extract_price(original)
      fields["quantity"] ||= original[/(\d+(?:\.\d+)?)\s*(?:акци[йияю]|shares?|contracts?|контракт[ао]?|μετοχ)/i, 1]
      date = original[/\b(?:on|дата|от|στις)\s+(\d{4}-\d{2}-\d{2})/i, 1]
      fields["effective_at"] ||= "#{date}T12:00:00Z" if date
      if original.match?(/сегодня|\btoday\b|σήμερα/i) && arguments["captured_at"]
        fields["effective_at"] ||= arguments["captured_at"]
      end
      essential = %w[owner_id account_id asset_id operation effective_at quantity price currency unit]
      missing = essential.reject { |field| fields[field] && !fields[field].to_s.empty? }
      opens = []
      closing = %w[CLOSE_LONG SELL CLOSE_SHORT].include?(fields["operation"])
      positions = owner ? @service.projection(owner_id: owner).positions.select do |p|
        (!fields["asset_id"] || p["asset_id"] == fields["asset_id"]) && (!fields["account_id"] || p["account_id"] == fields["account_id"])
      end : []
      if closing && positions.length == 1 && original.match?(/полностью|всю|all|entire|fully/i)
        fields["quantity"] ||= Decimal.text(Decimal.value(positions.first["quantity"]).abs)
        missing.delete("quantity") if fields["quantity"]
      end
      if closing && positions.empty?
        missing += %w[opening_date opening_price].reject { |field| fields[field] }
        if fields["basis_status"] == "unknown" && fields["confirmed"] == "true"
          missing.delete("opening_price")
        end
        if missing.empty?
          opening = build_event(fields).merge(
            "operation" => fields["basis_status"] == "unknown" ? "OPENING_BALANCE" : fields["operation"] == "CLOSE_SHORT" ? "OPEN_SHORT" : "BUY",
            "effective_at" => @service.timestamp(fields["opening_date"], end_of_day: false),
            "price" => fields["opening_price"], "metadata" => fields["basis_status"] == "unknown" ? { "confirmed" => true, "basis_status" => "unknown" } : {}
          )
          raise InvalidFinance, "opening date must precede closing date" if opening["effective_at"] > @service.timestamp(fields["effective_at"])
          opens << opening
        end
      end
      if intent == "finance.register_asset" || intent == "finance.register_liability"
        missing = intent == "finance.register_asset" ? %w[asset_identity owner_id ownership_share acquisition_date acquisition_price] : %w[creditor_id debtor_id owner_id account_id agreement_date currency principal]
      end
      return clarify(intent, missing.uniq, original, fields, arguments, candidates: assets, positions: positions) if missing.any?
      combined = use_pending ? "#{original}\n\nFinance clarification:\n#{text}" : original
      result = @proposals.rows(dataset: "finance_events", rows: opens + [build_event(fields)], arguments: arguments.merge("content" => combined))
      @state.save(arguments, { "status" => "resolved", "proposal_id" => result["proposal_id"] })
      result.merge("intent" => intent)
    rescue JSON::ParserError, KeyError
      raise InvalidFinance, "invalid structured finance request"
    end

    def build_event(fields)
      fields.slice("owner_id", "account_id", "asset_id", "operation", "quantity", "price", "currency", "unit", "fees", "amount", "effective_at").merge("metadata" => {})
    end

    def clarify(intent, missing, original, fields, arguments, candidates: [], positions: [])
      question = original.match?(/[а-я]/i) ?
        "Нужны уточнения: #{missing.join(', ')}. Исходные детали сохранены. Уточни инструмент, счёт и известную историю; неизвестная себестоимость останется неизвестной." :
        "Please supply: #{missing.join(', ')}. Original details are retained; unknown cost basis will remain unknown."
      payload = { "status" => "clarification_required", "intent" => intent,
        "sensitivity" => arguments.fetch("sensitivity", "private"),
        "missing_information" => missing, "question" => question, "original_text" => original, "fields" => fields,
        "candidates" => candidates.map { |a| { "asset_id" => a.id, "name" => a.data["name"], "asset_class" => a.data["asset_class"] } },
        "position_candidates" => positions, "planned_intent_count" => 0, "executable" => false, "execution_authorized" => false }
      @state.save(arguments, payload)
      payload
    end

    def parse_fields(text)
      allowed = %w[owner_id account_id asset_id operation effective_at opening_date opening_price quantity price amount unit currency fees confirmed basis_status as_of from to target deadline reporting_currency]
      text.scan(/([a-z_]+)=("[^"]*"|[^\s;]+)/).each_with_object({}) do |(key, value), fields|
        fields[key] = value.delete_prefix('"').delete_suffix('"') if allowed.include?(key)
      end
    end

    def extract_price(text)
      match = text.match(/(?:\bat\s+|по\s+|στα\s+)([$€]?)([0-9]+(?:[.,][0-9]+)*)/i)
      return nil unless match
      number = match[2]
      number = number.match?(/\A\d{1,3}(?:,\d{3})+(?:\.\d+)?\z/) ? number.delete(",") : number.tr(",", ".")
      Decimal.value(number)
      number
    end

    def matching_assets(text, fields = {})
      @service.matching_assets(text, fields)
    end

  end

  class Window
    attr_reader :from, :to, :historical
    def initialize(text, today, fields = {})
      @historical = false
      @from = fields["from"] || Date.new(today.year, 1, 1).iso8601
      @to = fields["to"] || today.iso8601
      if text.match?(/прошл[[:alpha:]]+\s+квартал|last\s+quarter/i)
        start = Date.new(today.year, ((today.month - 1) / 3) * 3 + 1, 1)
        @from = (start << 3).iso8601; @to = (start - 1).iso8601
      elsif text.match?(/12\s+месяц|last\s+(?:12\s+months|year)|past\s+year|monthly/i)
        @from = (today << 12).iso8601
      end
      months = %w[january february march april may june july august september october november december]
      russian = %w[январ февра мар апр ма июн июл август сентябр октябр ноябр декабр]
      month = months.each_with_index.find { |name, _| text.match?(/\b(?:in|during)\s+#{name}\b/i) } ||
        russian.each_with_index.find { |name, _| text.match?(/(?:в|за)\s+#{name}[[:alpha:]]*/i) }
      if month
        year = text[/\b(20\d{2})\b/, 1]&.to_i || (text.match?(/прошлого\s+года|last\s+year/i) ? today.year - 1 : today.year)
        first = Date.new(year, month[1] + 1, 1)
        @from = first.iso8601; @to = ((first >> 1) - 1).iso8601; @historical = true
      end
    end
  end
end
