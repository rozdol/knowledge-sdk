# frozen_string_literal: true

require "bigdecimal"
require "date"
require "json"
require "digest"

module KnowledgeFinance
  class Error < StandardError; end
  class InvalidFinance < Error; end
  class MissingHistory < InvalidFinance; end

  module Decimal
    PATTERN = /\A-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?\z/.freeze
    module_function

    def value(input)
      raise InvalidFinance, "exact decimal strings are required; Float is not accepted" if input.is_a?(Float)
      text = input.to_s
      raise InvalidFinance, "invalid decimal" unless text.length <= 80 && PATTERN.match?(text)

      BigDecimal(text)
    end

    def text(input)
      input.is_a?(BigDecimal) ? input.to_s("F") : value(input).to_s("F")
    end

    def positive!(input)
      number = value(input)
      raise InvalidFinance, "quantity, multiplier or rate must be positive" unless number > 0
      number
    end
  end

  # Typed identifiers are exact signals only. A display name never merges assets.
  class Identifiers
    IBAN_LENGTHS = {
      "AL"=>28,"AD"=>24,"AT"=>20,"AZ"=>28,"BH"=>22,"BE"=>16,"BA"=>20,"BR"=>29,
      "BG"=>22,"CR"=>22,"HR"=>21,"CY"=>28,"CZ"=>24,"DK"=>18,"DO"=>28,"EE"=>20,
      "FO"=>18,"FI"=>18,"FR"=>27,"GE"=>22,"DE"=>22,"GI"=>23,"GR"=>27,"GL"=>18,
      "GT"=>28,"HU"=>28,"IS"=>26,"IQ"=>23,"IE"=>22,"IL"=>23,"IT"=>27,"JO"=>30,
      "KZ"=>20,"XK"=>20,"KW"=>30,"LV"=>21,"LB"=>28,"LI"=>21,"LT"=>20,"LU"=>20,
      "MK"=>19,"MT"=>31,"MR"=>27,"MU"=>30,"MD"=>24,"MC"=>27,"ME"=>22,"NL"=>18,
      "NO"=>15,"PK"=>24,"PS"=>29,"PL"=>28,"PT"=>25,"QA"=>29,"RO"=>24,"LC"=>32,
      "SM"=>27,"ST"=>25,"SA"=>24,"RS"=>22,"SC"=>31,"SK"=>24,"SI"=>19,"ES"=>24,
      "SE"=>24,"CH"=>21,"TL"=>23,"TN"=>24,"TR"=>26,"UA"=>29,"AE"=>23,"GB"=>22,
      "VA"=>22,"VG"=>24,"BY"=>28,"SV"=>28,"LY"=>25,"SD"=>18,"BI"=>27,"DJ"=>27,
      "RU"=>33,"SO"=>23,"MN"=>20,"FK"=>18,"OM"=>23,"NI"=>28,"HN"=>28
    }.freeze
    TYPES = %w[isin figi cusip sedol ticker_mic conid future_contract option_contract iban
               bank_account broker_account cadastral vin registration agreement certificate serial user].freeze

    def initialize
      @cadastral = {}
    end

    def register_cadastral(jurisdiction, &validator)
      raise InvalidFinance, "validator must be trusted code" unless validator
      raise InvalidFinance, "cadastral validator already registered" if @cadastral.key?(jurisdiction.to_s.upcase)
      @cadastral[jurisdiction.to_s.upcase] = validator
    end

    def validate(items)
      Array(items).map do |raw|
        item = raw.transform_keys(&:to_s)
        type = item.fetch("type")
        val = item.fetch("value").to_s
        raise InvalidFinance, "unsupported identifier type" unless TYPES.include?(type)
        raise InvalidFinance, "identifier is empty" if val.strip.empty?
        normalized = %w[isin iban vin].include?(type) ? val.upcase.delete(" ") : val
        valid = case type
                when "isin" then isin?(normalized)
                when "iban" then iban?(normalized)
                when "vin" then normalized.match?(/\A[A-HJ-NPR-Z0-9]{17}\z/)
                when "ticker_mic" then val.match?(/\A[^: ]+:[A-Z0-9]{4}\z/)
                when "conid" then val.match?(/\A[1-9][0-9]*\z/)
                when "cadastral"
                  jurisdiction = item.fetch("jurisdiction", "").upcase
                  !jurisdiction.empty? && (!@cadastral[jurisdiction] || @cadastral[jurisdiction].call(val))
                else true
                end
        raise InvalidFinance, "invalid #{type} identifier" unless valid
        item.merge("value" => normalized)
      end
    rescue KeyError, NoMethodError
      raise InvalidFinance, "identifiers require typed objects with type and value"
    end

    def isin?(value)
      return false unless value.match?(/\A[A-Z]{2}[A-Z0-9]{9}[0-9]\z/)
      digits = value.chars.map { |c| c.match?(/[A-Z]/) ? (c.ord - 55).to_s : c }.join
      digits.reverse.chars.each_with_index.sum do |c, i|
        n = c.to_i * (i.odd? ? 2 : 1)
        n / 10 + n % 10
      end % 10 == 0
    end

    def iban?(value)
      return false unless value.match?(/\A[A-Z]{2}[0-9]{2}[A-Z0-9]+\z/) && IBAN_LENGTHS[value[0, 2]] == value.length
      expanded = (value[4..-1] + value[0, 4]).chars.map { |c| c.match?(/[A-Z]/) ? (c.ord - 55).to_s : c }.join
      expanded.each_char.reduce(0) { |mod, c| (mod * 10 + c.to_i) % 97 } == 1
    end
  end

  def self.identifiers
    @identifiers ||= Identifiers.new
  end

  class Catalog
    CLASSES = %w[stock etf bond mutual_fund future option futures_option commodity precious_metal
                 cash real_estate land vehicle movable collectible artwork loan credit_card credit_facility other].freeze
    attr_reader :root

    def initialize(vault_root:)
      @root = File.expand_path(vault_root.to_s)
    end

    def repository
      KnowledgeGraph::Repository.new(vault_root: root, registry: KnowledgeGraph::SchemaRegistry.new(vault_root: root))
    end

    def snapshot
      SnapshotCatalog.new(KnowledgeIntelligence::GraphSnapshot.load(vault_root: root))
    end

    def records(type)
      repository.each_record.select { |record| record.type == type && record.data["record_status"] == "active" }
    end

    def installed?
      registry = KnowledgeGraph::SchemaRegistry.new(vault_root: root)
      %w[financial_asset financial_account financial_owner].all? { |type| registry.key?(type) }
    end

    def require_installed!
      raise InvalidFinance, "install the finance plugin explicitly: kg plugin install finance" unless installed?
    end

    def resolve(id, type = nil)
      record = repository.resolve(id)
      raise InvalidFinance, "financial reference must be an immutable ID" unless record.id == id
      raise InvalidFinance, "wrong financial reference type" if type && record.type != type
      record
    rescue KnowledgeGraph::Error
      raise InvalidFinance, "financial graph reference does not exist in this Vault"
    end

    def asset(id)
      resolve(id, "financial_asset")
    end

    def details(record)
      JSON.parse(record.data.fetch("details_json", "{}"))
    rescue JSON::ParserError
      raise InvalidFinance, "invalid financial metadata JSON"
    end

    def contract_digest(id)
      record = asset(id)
      payload = record.data.slice("asset_class", "currency", "unit", "multiplier", "identifiers_json", "details_json")
      Digest::SHA256.hexdigest(KnowledgeExtraction::Support.canonical_json(payload))
    end

    def owner!(id)
      record = resolve(id)
      raise InvalidFinance, "owner must identify a Person, Organization or Financial Owner" unless
        %w[person organization financial_owner].include?(record.type)
      record
    end

    def validate_record!(type, data, previous: nil)
      return unless %w[financial_asset financial_account financial_owner].include?(type)
      if data["id"] && !data["id"].match?(/\A#{type.delete('_')}_[0-9A-HJKMNP-TV-Z]{26}\z/)
        raise InvalidFinance, "financial identities require immutable typed ULID IDs"
      end
      raise InvalidFinance, "financial identity and contract terms are immutable; register a successor" if
        previous && (data.reject { |k, _| %w[updated_at updated_by updated_by_run].include?(k) } !=
                     previous.reject { |k, _| %w[updated_at updated_by updated_by_run].include?(k) })
      raise InvalidFinance, "financial records require provenance and sensitivity" if
        data["provenance"].to_s.empty? || !%w[normal private restricted].include?(data["sensitivity"])
      if type == "financial_owner"
        raise InvalidFinance, "owner_kind must be personal or corporate" unless %w[personal corporate].include?(data["owner_kind"])
        return
      end
      owners = Array(data["owner_ids"])
      raise InvalidFinance, "explicit owner_ids are required" if owners.empty?
      owners.each do |id|
        if owner!(id).data["sensitivity"] == "restricted" && data["sensitivity"] != "restricted"
          raise InvalidFinance, "restricted owners require restricted financial identities"
        end
      end
      KnowledgeFinance.identifiers.validate(JSON.parse(data.fetch("identifiers_json", "[]")))
      if type == "financial_account"
        account_terms = details(Struct.new(:data).new(data))
        owner!(account_terms["custodian_id"]) if account_terms["custodian_id"]
        return
      end
      raise InvalidFinance, "unsupported asset class" unless CLASSES.include?(data["asset_class"])
      raise InvalidFinance, "currency and unit are required" unless data["currency"].to_s.match?(/\A[A-Z]{3}\z/) && !data["unit"].to_s.empty?
      Decimal.positive!(data.fetch("multiplier"))
      if %w[stock etf mutual_fund].include?(data["asset_class"]) && Decimal.value(data["multiplier"]) != 1
        raise InvalidFinance, "equity quantities are shares; the multiplier must be one"
      end
      meta = details(Struct.new(:data).new(data))
      required = case data["asset_class"]
                 when "future" then %w[exchange contract_month expiry]
                 when "option", "futures_option" then %w[underlying_id exchange expiry strike put_call settlement]
                 when "bond" then %w[issuer_id maturity coupon price_basis]
                 when "real_estate", "land" then %w[jurisdiction]
                 when "loan", "credit_card", "credit_facility" then %w[creditor_id debtor_id direction agreement_date]
                 else []
                 end
      raise InvalidFinance, "missing asset terms: #{required.reject { |key| meta[key] }}" unless required.all? { |key| meta[key] }
      %w[underlying_id issuer_id creditor_id debtor_id custodian_id].each do |key|
        next unless meta[key]
        reference = resolve(meta[key])
        raise InvalidFinance, "restricted contract references require restricted assets" if reference.data["sensitivity"] == "restricted" && data["sensitivity"] != "restricted"
      end
      %w[expiry maturity agreement_date].each { |key| Date.iso8601(meta[key]) if meta[key] }
      if data["asset_class"] == "bond"
        owner!(meta["issuer_id"])
        Decimal.value(meta["coupon"])
        raise InvalidFinance, "bond accounting requires dirty prices per 100 nominal" unless
          meta["price_basis"] == "dirty_per_100" && Decimal.value(data["multiplier"]) == BigDecimal("0.01") && data["unit"] == "nominal"
      end
      if %w[loan credit_card credit_facility].include?(data["asset_class"])
        Array(meta["repayment_schedule"]).each do |payment|
          Date.iso8601(payment.fetch("due_on"))
          raise InvalidFinance, "scheduled principal must be nonnegative" if Decimal.value(payment.fetch("principal")) < 0
        end
        [meta.fetch("creditor_id"), meta.fetch("debtor_id")].each do |id|
          if owner!(id).data["sensitivity"] == "restricted" && data["sensitivity"] != "restricted"
            raise InvalidFinance, "restricted counterparties require restricted loan identities"
          end
        end
        raise InvalidFinance, "invalid loan direction" unless %w[receivable payable].include?(meta["direction"])
        raise InvalidFinance, "creditor and debtor must differ" if meta["creditor_id"] == meta["debtor_id"]
        expected = meta[meta["direction"] == "receivable" ? "creditor_id" : "debtor_id"]
        raise InvalidFinance, "loan direction conflicts with owner" unless owners == [expected]
      end
      if %w[option futures_option].include?(data["asset_class"])
        asset(meta["underlying_id"])
        Decimal.positive!(meta["strike"])
        raise InvalidFinance, "put_call must be put or call" unless %w[put call].include?(meta["put_call"])
        raise InvalidFinance, "settlement must be cash or physical" unless %w[cash physical].include?(meta["settlement"])
      end
    rescue JSON::ParserError, KeyError, ArgumentError
      raise InvalidFinance, "incomplete or invalid financial identity metadata"
    end

    def validate_event!(event)
      owner!(event.fetch("owner_id"))
      account = resolve(event.fetch("account_id"), "financial_account")
      instrument = asset(event.fetch("asset_id"))
      [account, instrument].each do |record|
        raise InvalidFinance, "owner does not own the account/asset" unless Array(record.data["owner_ids"]).include?(event["owner_id"])
      end
      [account, instrument, owner!(event["owner_id"])].each do |record|
        if record.data["sensitivity"] == "restricted" && event["sensitivity"] != "restricted"
          raise InvalidFinance, "restricted references require restricted financial events"
        end
      end
      raise InvalidFinance, "asset currency differs from event currency" unless instrument.data["currency"] == event["currency"]
      instrument
    end
  end
end
