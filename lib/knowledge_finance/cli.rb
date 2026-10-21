# frozen_string_literal: true

require "optparse"

module KnowledgeFinance
  class CLI
    def initialize(argv:, out:, err:, vault_root:, event_bus: nil, actor_id: nil)
      @argv = argv.dup
      @out = out
      @err = err
      @root = vault_root
      @event_bus = event_bus
      @actor_id = actor_id
    end

    def run
      command = @argv.shift || "help"
      options = {}
      parser = OptionParser.new do |p|
        p.banner = "Usage: kg finance assets|accounts|positions|transactions|debts|networth|pnl|performance|history|liquidity|propose|import|reconcile [options]"
        p.on("--owner ID") { |v| options[:owner_id] = v }
        p.on("--asset ID") { |v| options[:asset_id] = v }
        p.on("--account ID") { |v| options[:account_id] = v }
        p.on("--as-of TIME") { |v| options[:as_of] = v }
        p.on("--from TIME") { |v| options[:from] = v }
        p.on("--to TIME") { |v| options[:to] = v }
        p.on("--currency CODE") { |v| options[:currency] = v }
        p.on("--target DECIMAL") { |v| options[:target] = v }
        p.on("--deadline DATE") { |v| options[:deadline] = v }
        p.on("--file PATH") { |v| options[:file] = v }
        p.on("--dataset NAME") { |v| options[:dataset] = v }
        p.on("--source NAME") { |v| options[:source] = v }
        p.on("--statement-offset OFFSET", "Explicit timezone for broker-local Flex timestamps") { |v| options[:timezone_offset] = v }
        p.on("--json") { options[:json] = true }
        p.on("--monthly") { options[:monthly] = true }
        p.on("--help") { command = "help" }
      end
      parser.parse!(@argv)
      raise InvalidFinance, "unexpected finance arguments" unless @argv.empty?
      if command == "help"
        @out.puts(parser)
        return 0
      end
      service = Service.new(vault_root: @root)
      service.catalog.require_installed!
      owner = service.owner_scope(options[:owner_id])
      result = case command
               when "assets", "accounts"
                 type = command == "assets" ? "financial_asset" : "financial_account"
                 { "status" => "ok", command => service.catalog.records(type).select { |r| service.visible?("asset_id" => r.id) && (!owner || Array(r.data["owner_ids"]).include?(owner)) }.map(&:data), "execution_authorized" => false }
               when "positions"
                 service.holdings(**options.slice(:owner_id, :asset_id, :as_of))
               when "transactions", "history"
                 if owner
                   rows = service.rows("finance_events").select { |r| r["owner_id"] == owner && (!options[:asset_id] || r["asset_id"] == options[:asset_id]) }
                   rows.select! { |r| r["effective_at"] <= service.timestamp(options[:as_of]) }
                   rows.select! { |r| r["account_id"] == options[:account_id] } if options[:account_id]
                   rows.select! { |r| r["effective_at"] >= service.timestamp(options[:from], end_of_day: false) } if options[:from]
                   rows.select! { |r| r["effective_at"] <= service.timestamp(options[:to]) } if options[:to]
                   { "status" => "ok", "events" => rows, "execution_authorized" => false }
                 else service.scope_clarification
                 end
               when "debts" then service.debt_report(**options.slice(:owner_id, :as_of))
               when "networth" then service.networth(**options.slice(:owner_id, :as_of, :currency))
               when "pnl"
                 args = options.slice(:owner_id, :from, :to, :asset_id, :account_id)
                 raise InvalidFinance, "pnl requires --from and --to" unless args[:from] && args[:to]
                 options[:monthly] ? service.monthly(**args) : service.pnl(**args)
               when "performance"
                 raise InvalidFinance, "performance requires --from and --to" unless options[:from] && options[:to]
                 service.performance(**options.slice(:owner_id, :from, :to, :currency))
               when "liquidity"
                 raise InvalidFinance, "liquidity requires --target" unless options[:target]
                 service.liquidity(**options.slice(:owner_id, :target, :currency, :deadline, :as_of))
               when "propose"
                 file = Pathname.new(options.fetch(:file))
                 raise InvalidFinance, "finance request exceeds 1 MB" if file.size > 1_000_000
                 Conversation.new(vault_root: @root, event_bus: @event_bus).propose("source_type" => "text", "content" => file.read, "source_uri" => file.expand_path.to_s, "sender" => @actor_id)
               when "import"
                 Importer.new(proposals: Proposals.new(vault_root: @root, event_bus: @event_bus)).propose(
                   path: options.fetch(:file), dataset: options.fetch(:dataset, "finance_events"), source: options.fetch(:source, "manual-statement"),
                   owner_id: options[:owner_id], account_id: options[:account_id], timezone_offset: options[:timezone_offset]
                 )
               when "reconcile"
                 raise InvalidFinance, "reconcile requires --owner and --as-of" unless owner && options[:as_of]
                 Importer.new(proposals: Proposals.new(vault_root: @root)).reconcile(
                   snapshots: JSON.parse(File.read(options.fetch(:file))), owner_id: owner, as_of: options[:as_of]
                 )
               else raise InvalidFinance, "unknown finance command"
               end
      @out.puts(JSON.pretty_generate(result))
      0
    rescue KnowledgeFinance::Error, StructuredDataset::Error, KnowledgeGraph::Error, KnowledgeExtraction::Error,
           KeyError, ArgumentError, OptionParser::ParseError, JSON::ParserError, Errno::ENOENT => error
      payload = { "status" => "error", "error" => { "code" => error.class.name.split("::").last, "message" => error.message } }
      @out.puts(JSON.pretty_generate(payload))
      1
    end
  end
end
