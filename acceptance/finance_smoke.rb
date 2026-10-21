#!/usr/bin/env ruby
# frozen_string_literal: true

# Independent synthetic CLI/SDK acceptance. No attached user Vault is inspected.
require "tmpdir"
require "stringio"
require_relative "../lib/knowledge_graph"

clock = -> { Time.utc(2026, 10, 21, 12) }
Dir.mktmpdir("knowledge-finance-smoke-") do |root|
  FileUtils.mkdir_p(File.join(root, ".obsidian"))
  configuration = File.join(root, "synthetic-sdk.yml")
  results = {}
  cli = lambda do |*args|
    out = StringIO.new; err = StringIO.new
    status = KnowledgeGraph::CLI.run(["--vault", root, "--config", configuration, *args], out: out, err: err, stdin: StringIO.new)
    raise "CLI failed: #{args.first}: #{err.string} #{out.string}" unless status.zero?
    begin
      JSON.parse(out.string)
    rescue JSON::ParserError
      out.string.strip
    end
  end
  results["installation"] = cli.call("plugin", "install", "finance")
  proposals = KnowledgeFinance::Proposals.new(vault_root: root, clock: clock)
  graph = KnowledgeGraph::Engine.new(vault_root: root, clock: clock, actor_id: "synthetic-human")
  submit = lambda do |result|
    id = result.fetch("proposal_id")
    stored = proposals.store.load(id)
    proposals.store.approve(proposal_id: id, intent_ids: stored["planned_intents"].map { |i| i["planned_intent_id"] }, actor_id: "synthetic-human")
    receipt = KnowledgeExtraction::ProposalSubmitter.new(engine: graph, store: proposals.store, clock: clock).submit(id)
    raise "Synthetic submission failed: #{JSON.generate(receipt)}" unless receipt["status"] == "executed"
  end
  source = ->(value) { { "content" => JSON.generate(value), "source_type" => "text", "captured_at" => clock.call.iso8601, "origin_source" => "synthetic-acceptance" } }
  ids = { owner: KnowledgeExtraction::Support.stable_id("financialowner", "synthetic-owner"),
          account: KnowledgeExtraction::Support.stable_id("financialaccount", "synthetic-account"),
          asset: KnowledgeExtraction::Support.stable_id("financialasset", "synthetic-msft") }
  [
    ["owner", { id: ids[:owner], name: "Synthetic Finance Owner", owner_kind: "personal" }],
    ["account", { id: ids[:account], name: "Synthetic Finance Account", owner_ids: [ids[:owner]] }],
    ["asset", { id: ids[:asset], name: "Microsoft", owner_ids: [ids[:owner]], asset_class: "stock", currency: "USD", unit: "share", multiplier: "1", identifiers: [{ type: "isin", value: "US5949181045" }] }]
  ].each { |kind, attributes| submit.call(proposals.register(kind: kind, attributes: attributes, arguments: source.call(attributes))) }
  rows = [["BUY", "2026-01-02", "20", "300"], ["BUY", "2026-02-02", "15", "350"], ["SELL", "2026-03-02", "5", "400"]].map do |op, date, quantity, price|
    { operation: op, effective_at: "#{date}T12:00:00Z", owner_id: ids[:owner], account_id: ids[:account], asset_id: ids[:asset], quantity: quantity, price: price, unit: "share", currency: "USD" }
  end
  submit.call(proposals.rows(dataset: "finance_events", rows: rows, arguments: source.call(rows)))
  results["chat"] = cli.call("chat", "--text", "Сколько у меня акций Microsoft?", "--json")
  raise "CLI holdings mismatch" unless results["chat"].dig("result", "holdings", 0, "quantity") == "30.0"
  results["positions"] = cli.call("finance", "positions", "--owner", ids[:owner], "--json")
  results["pnl"] = cli.call("finance", "pnl", "--owner", ids[:owner], "--from", "2026-01-01", "--to", "2026-03-31", "--json")
  raise "CLI P&L mismatch" unless results["pnl"].dig("totals", 0, "realized_pnl") == "500.0"
  results["search"] = cli.call("search", "Сколько у меня акций Microsoft?")
  results["doctor"] = cli.call("doctor")
  results["validate"] = cli.call("validate")
  puts JSON.pretty_generate("status" => "passed", "synthetic_only" => true, "checks" => results)
end
