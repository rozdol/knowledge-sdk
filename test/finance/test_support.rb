# frozen_string_literal: true

require_relative "../test_helper"
require "stringio"

module FinanceTestSupport
  NOW = Time.utc(2026, 10, 21, 12)
  OWNER = "financialowner_01KYYD4HNT4HEWNH1P3DQKTPPF"
  ACCOUNT = "financialaccount_01KYYD4HNT4HEWNH1P3DQKTPPF"
  ASSET = "financialasset_01KYYD4HNT4HEWNH1P3DQKTPPF"
  SECOND_ACCOUNT = "financialaccount_01KYYD4HNT4HEWNH1P3DQKTPPG"
  SECOND_ASSET = "financialasset_01KYYD4HNT4HEWNH1P3DQKTPPG"

  def with_finance(account_details: {})
    with_schema_vault do |root|
      KnowledgeSDK::PluginRegistry.new.install("finance", root)
      @finance_root = root
      @graph = KnowledgeGraph::Engine.new(vault_root: root, clock: -> { NOW }, actor_id: "finance-human")
      @datasets = StructuredDataset::Engine.new(vault_root: root, clock: -> { NOW })
      @finance = KnowledgeFinance::Proposals.new(vault_root: root, dataset_engine: @datasets, clock: -> { NOW })
      register_finance("owner", id: OWNER, name: "Synthetic Owner", owner_kind: "personal")
      register_finance("account", id: ACCOUNT, name: "Synthetic Broker", owner_ids: [OWNER], details: account_details)
      register_finance("asset", id: ASSET, name: "Microsoft", aliases: ["MSFT"], owner_ids: [OWNER], asset_class: "stock", currency: "USD", unit: "share", multiplier: "1", identifiers: [{ type: "isin", value: "US5949181045" }])
      yield root
    end
  end

  def args(content)
    { "content" => content, "source_type" => "text", "captured_at" => NOW.iso8601(6), "origin_source" => "synthetic" }
  end

  def register_finance(kind, attributes)
    attributes = attributes.transform_keys(&:to_s)
    result = @finance.register(kind: kind, attributes: attributes, arguments: args(JSON.generate(attributes)))
    submit_finance(result)
    result
  end

  def submit_finance(result, approve: true)
    id = result.fetch("proposal_id")
    proposal = @finance.store.load(id)
    if approve
      @finance.store.approve(proposal_id: id, intent_ids: proposal["planned_intents"].map { |i| i["planned_intent_id"] }, actor_id: "finance-human")
    end
    receipt = KnowledgeExtraction::ProposalSubmitter.new(engine: @graph, store: @finance.store, dataset_engine: @datasets, clock: -> { NOW }).submit(id)
    assert_equal "executed", receipt["status"], JSON.pretty_generate(receipt) if approve
    receipt
  end

  def event(operation, date:, quantity: "0", price: nil, **extra)
    { "operation" => operation, "effective_at" => "#{date}T12:00:00Z", "owner_id" => OWNER,
      "account_id" => ACCOUNT, "asset_id" => ASSET, "quantity" => quantity, "price" => price,
      "currency" => "USD", "unit" => "share" }.merge(extra.transform_keys(&:to_s))
  end

  def post_events(rows, **arguments)
    result = @finance.rows(dataset: "finance_events", rows: rows, arguments: args(JSON.generate(rows)).merge(arguments.transform_keys(&:to_s)))
    submit_finance(result)
    result
  end

  def post_observations(rows)
    result = @finance.rows(dataset: "finance_observations", rows: rows, arguments: args(JSON.generate(rows)))
    submit_finance(result)
    result
  end

  def service(**options)
    KnowledgeFinance::Service.new(vault_root: @finance_root, dataset_engine: @datasets, clock: -> { NOW }, **options)
  end

  def observation(type: "price", asset_id: ASSET, value: "400", as_of: "2026-10-20T12:00:00Z", **options)
    { "observation_key" => KnowledgeExtraction::Support.stable_id("price", type, asset_id, value, as_of, JSON.generate(options)),
      "observation_type" => type, "owner_id" => OWNER, "asset_id" => asset_id, "value" => value,
      "currency" => "USD", "price_type" => "last", "as_of" => as_of, "retrieved_at" => NOW.iso8601(6),
      "quality" => "verified", "sensitivity" => "private", "metadata" => {} }.merge(options.transform_keys(&:to_s))
  end
end
