# frozen_string_literal: true

module DashboardFinanceFixture
  OWNER = "financialowner_00000000000000000000000001"
  ACCOUNT = "financialaccount_00000000000000000000000001"
  ASSET = "financialasset_00000000000000000000000001"

  def self.build(root)
    KnowledgeSDK::PluginRegistry.new.install("finance", root)
    engine = KnowledgeGraph::Engine.new(vault_root: root)
    datasets = StructuredDataset::Engine.new(vault_root: root)
    proposals = KnowledgeFinance::Proposals.new(vault_root: root, dataset_engine: datasets)
    args = { "content" => "Synthetic Finance fixture", "source_type" => "text", "origin_source" => "synthetic", "captured_at" => Time.now.utc.iso8601 }
    submit = lambda do |result|
      id = result.fetch("proposal_id")
      planned = proposals.store.load(id).fetch("planned_intents").map { |item| item["planned_intent_id"] }
      proposals.store.approve(proposal_id: id, intent_ids: planned, actor_id: "synthetic-human")
      receipt = KnowledgeExtraction::ProposalSubmitter.new(engine: engine, store: proposals.store, dataset_engine: datasets).submit(id)
      raise "synthetic finance fixture failed" unless receipt["status"] == "executed"
    end
    [[:owner, { id: OWNER, name: "Synthetic owner <img src=x onerror=window.injected=true>", owner_kind: "personal" }],
      [:account, { id: ACCOUNT, name: "Synthetic account", owner_ids: [OWNER] }],
      [:asset, { id: ASSET, name: "Synthetic stock", owner_ids: [OWNER], asset_class: "stock", currency: "USD", unit: "share", multiplier: "1" }]].each do |kind, attrs|
      submit.call(proposals.register(kind: kind.to_s, attributes: attrs.transform_keys(&:to_s), arguments: args))
    end
    today = Time.now.utc.to_date
    events = [
      { "operation" => "BUY", "effective_at" => "#{today - 40}T12:00:00Z", "quantity" => "0.3", "price" => "0.2", "fees" => "0.001" },
      { "operation" => "SELL", "effective_at" => "#{today}T12:00:00Z", "quantity" => "0.1", "price" => "0.4", "fees" => "0" }
    ].map { |event| event.merge("owner_id" => OWNER, "account_id" => ACCOUNT, "asset_id" => ASSET, "unit" => "share", "currency" => "USD") }
    submit.call(proposals.rows(dataset: "finance_events", rows: events, arguments: args))
    submit.call(proposals.rows(dataset: "finance_observations", rows: [{ "observation_key" => "synthetic-price", "observation_type" => "price", "owner_id" => OWNER,
      "asset_id" => ASSET, "value" => "0.4", "currency" => "USD", "price_type" => "last", "as_of" => "#{today}T00:00:00Z",
      "retrieved_at" => Time.now.utc.iso8601, "quality" => "verified", "sensitivity" => "private", "metadata" => {} }], arguments: args))
  end

  def self.logical(root)
    reader = StructuredDataset::Reader.new(vault_root: root, database_path: File.join(root, KnowledgeSDK::DATASET_PATH))
    reader.with_consistent_read do
      %w[finance_events finance_observations].map { |slug| [reader.describe(slug), reader.query(slug, order: "row_id:asc", limit: 100)] }
    end
  end
end
