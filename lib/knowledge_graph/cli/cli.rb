# frozen_string_literal: true

require "json"
require "digest"
require "fileutils"
require "open3"
require "optparse"
require "pathname"
require "rbconfig"

module KnowledgeGraph
  class CLI
    def self.run(argv = ARGV, out: $stdout, err: $stderr, stdin: $stdin)
      new(argv.dup, out: out, err: err, stdin: stdin).run
    end

    def initialize(argv, out:, err:, stdin:)
      @argv = argv
      @out = out
      @err = err
      @stdin = stdin
      @options = {
        vault_root: nil, config_path: ENV["KG_CONFIG"],
        dataset_db: ENV["KG_DATASET_DB"],
        run_id: ENV["KG_RUN_ID"], actor_id: ENV["KG_ACTOR_ID"]
      }
    end

    def run
      parser.order!(@argv)
      KnowledgeSDK.config_path = @options[:config_path] if @options[:config_path]
      KnowledgeSDK.dataset_path_override = @options[:dataset_db]
      command = @argv.shift
      return print_help(parser) unless command

      case command
      when "init" then init_command
      when "attach" then attach_command
      when "detach" then detach_command
      when "upgrade" then upgrade_command
      when "migrate" then migrate_command
      when "version" then version_command
      when "id" then id_command
      when "vault" then vault_command
      when "plugin" then plugin_command
      when "execute" then execute_command
      when "validate" then validate_command
      when "doctor" then doctor_command
      when "graph" then graph_command
      when "stats" then stats_command
      when "search" then search_command
      when "replay" then replay_command
      when "gateway" then gateway_command
      when "dataset" then StructuredDataset::CLI.new(
        argv: @argv, out: @out, err: @err, vault_root: vault_root,
        run_id: @options[:run_id], actor_id: @options[:actor_id], event_bus: orchestrator.event_bus
      ).run
      when "activity" then KnowledgeActivity::CLI.new(
        argv: @argv, out: @out, err: @err, vault_root: vault_root,
        event_bus: orchestrator.event_bus, cache: orchestrator.cache
      ).run
      when "events", "workflow", "scheduler", "notifications", "cache"
        KnowledgeOrchestration::CLI.new(
          group: command, argv: @argv, out: @out, err: @err, orchestrator: orchestrator
        ).run
      when "intelligence" then KnowledgeIntelligence::CLI.new(
        argv: @argv, out: @out, err: @err, vault_root: vault_root
      ).run
      when "goal", "plan" then KnowledgePlanning::CLI.new(
        group: command, argv: @argv, out: @out, err: @err, stdin: @stdin,
        vault_root: vault_root, event_bus: orchestrator.event_bus
      ).run
      when "chat" then ChatCLI.new(
        argv: @argv, out: @out, err: @err, stdin: @stdin,
        vault_root: vault_root, gateway: agent_gateway,
        event_bus: orchestrator.event_bus, cache: orchestrator.cache,
        actor_id: @options[:actor_id]
      ).run
      when "observe" then KnowledgeExtraction::ObservationCLI.new(
        argv: @argv, out: @out, err: @err, stdin: @stdin,
        vault_root: vault_root, gateway: agent_gateway,
        event_bus: orchestrator.event_bus, cache: orchestrator.cache,
        actor_id: @options[:actor_id]
      ).run
      when "extract", "proposal" then KnowledgeExtraction::CLI.new(
        command: command, argv: @argv, out: @out, err: @err,
        vault_root: vault_root, run_id: @options[:run_id], actor_id: @options[:actor_id],
        event_bus: orchestrator.event_bus
      ).run
      when "help", "--help", "-h" then print_help(parser)
      else
        raise InvalidIntent, "unknown command #{command.inspect}"
      end
    rescue OptionParser::ParseError, JSON::ParserError, InvalidIntent, KnowledgeSDK::Error => error
      @err.puts(JSON.generate(error: error.message))
      2
    rescue KnowledgeGraph::Error => error
      @err.puts(JSON.generate(error: error.message, error_class: error.class.name))
      1
    rescue KnowledgeExtraction::Error => error
      @err.puts(JSON.generate(error: error.message, error_class: error.class.name))
      1
    rescue KnowledgeOrchestration::Error => error
      @err.puts(JSON.generate(error: error.message, error_class: error.class.name))
      1
    rescue StructuredDataset::Error => error
      @err.puts(JSON.generate(error: error.message, error_class: error.class.name))
      1
    end

    private

    def parser
      @parser ||= OptionParser.new do |options|
        options.banner = "Usage: kg [options] COMMAND [arguments]"
        options.on("--vault PATH", "Vault root (default: current directory)") do |path|
          @options[:vault_root] = path
        end
        options.on("--config PATH", "SDK configuration file") { |path| @options[:config_path] = path }
        options.on("--dataset-db PATH", "Override the active Vault dataset database") do |path|
          @options[:dataset_db] = path
        end
        options.on("--run-id RUN_ID", "Agent run ID") { |value| @options[:run_id] = value }
        options.on("--actor-id ACTOR_ID", "Future actor/audit identifier") { |value| @options[:actor_id] = value }
        options.on("-h", "--help", "Show help") { @options[:help] = true }
      end
    end

    def init_command
      options = { attach: true, profile: nil, name: nil }
      OptionParser.new do |parser|
        parser.on("--[no-]attach", "Register the new Vault (default: true)") { |value| options[:attach] = value }
        parser.on("--profile NAME", "Install an optional Vault profile") { |value| options[:profile] = value }
        parser.on("--name NAME", "Display name in the SDK registry") { |value| options[:name] = value }
      end.parse!(@argv)
      target = Pathname.new(@argv.shift || ".").expand_path
      FileUtils.mkdir_p(target)
      FileUtils.mkdir_p(target.join(".obsidian"))
      installed = options[:profile] ? plugin_registry.install(options[:profile], target) : []
      record = options[:attach] ? registry.attach(target, name: options[:name], profile: options[:profile]) : nil
      emit_json(vault: target.to_s, attached: !!record, profile: options[:profile], installed: installed)
      0
    end

    def attach_command
      options = { name: nil, profile: nil }
      OptionParser.new do |parser|
        parser.on("--name NAME", "Registry display name") { |value| options[:name] = value }
        parser.on("--profile NAME", "Optional SDK plugin/profile") { |value| options[:profile] = value }
      end.parse!(@argv)
      path = @argv.shift || raise(KnowledgeSDK::VaultNotFound, "attach expects a Vault path")
      plugin_registry.fetch(options[:profile]) if options[:profile]
      emit_json(vault: registry.attach(path, name: options[:name], profile: options[:profile]))
      0
    end

    def detach_command
      reference = @argv.shift || raise(KnowledgeSDK::VaultNotFound, "detach expects a Vault name, ID, or path")
      record = registry.detach(reference)
      emit_json(detached: record, vault_modified: false)
      0
    end

    def upgrade_command
      emit_json(
        sdk_version: KnowledgeSDK::VERSION,
        config_version: KnowledgeSDK::Configuration::FORMAT_VERSION,
        registered_vaults: registry.all.length,
        status: "ok"
      )
      0
    end

    def migrate_command
      options = { prune_embedded: false, rollback: nil }
      OptionParser.new do |parser|
        parser.on("--prune-embedded-sdk", "Move embedded SDK/tooling to a rollback backup") do
          options[:prune_embedded] = true
        end
        parser.on("--rollback PATH", "Restore a migration backup") { |value| options[:rollback] = value }
      end.parse!(@argv)
      record = registry.find(vault_root.to_s)
      backup_key = record ? record.fetch("id") : Digest::SHA256.hexdigest(vault_root.to_s)[0, 16]
      migration = KnowledgeSDK::Migration.new(
        vault_root: vault_root,
        backup_root: Pathname.new(KnowledgeSDK.config_path).expand_path.dirname.join("backups", backup_key)
      )
      result = if options[:rollback]
                 { vault: vault_root.to_s, restored: migration.rollback!(options[:rollback]) }
               else
                 migration.migrate!(prune_embedded: options[:prune_embedded])
               end
      emit_json(result)
      0
    end

    def version_command
      emit_json(product: "knowledge-sdk", version: KnowledgeSDK::VERSION)
      0
    end

    def id_command
      prefix = @argv.shift || raise(InvalidIntent, "id expects a lowercase prefix")
      raise InvalidIntent, "invalid ID prefix" unless prefix.match?(/\A[a-z][a-z0-9-]{0,31}\z/)

      @out.puts(KnowledgeGraph::IdGenerator.new.generate(prefix))
      0
    end

    def vault_command
      action = @argv.shift || "list"
      case action
      when "list"
        emit_json(active_vault: registry.current && registry.current.fetch("id"), vaults: registry.all)
      when "use"
        emit_json(vault: registry.use(@argv.shift || raise(KnowledgeSDK::VaultNotFound, "vault use expects a reference")))
      when "current"
        record = registry.current || raise(KnowledgeSDK::VaultNotFound, "no active Vault is configured")
        emit_json(vault: record)
      else
        raise InvalidIntent, "unknown vault command #{action.inspect}"
      end
      0
    end

    def plugin_command
      action = @argv.shift || "list"
      case action
      when "list"
        emit_json(plugins: plugin_registry.all.map { |plugin| plugin.reject { |key, _value| key == "root" } })
      when "install"
        name = @argv.shift || raise(InvalidIntent, "plugin install expects a name")
        installed = plugin_registry.install(name, vault_root)
        registry.attach(vault_root, profile: name) if registry.find(vault_root.to_s)
        emit_json(plugin: name, vault: vault_root.to_s, installed: installed)
      else
        raise InvalidIntent, "unknown plugin command #{action.inspect}"
      end
      0
    end

    def execute_command
      source = @argv.shift
      source = @stdin.read if source.nil? || source == "-"
      raise InvalidIntent, "execute expects a JSON payload or '-'" if source.to_s.strip.empty?

      intent = IntentFactory.build(JSON.parse(source))
      emit_result(engine.execute(intent))
      0
    end

    def validate_command
      stdout, stderr, status = run_validator
      @out.write(stdout) unless stdout.empty?
      @err.write(stderr) unless stderr.empty?
      status.success? ? 0 : 1
    end

    def doctor_command
      stdout, stderr, status = run_validator
      registry = schema_registry
      relationships = relationship_registry
      dataset_status = dataset_health
      emit_json(
        status: status.success? && dataset_status.fetch(:status) == "ok" ? "ok" : "failed",
        sdk_version: KnowledgeSDK::VERSION,
        vault: vault_root.to_s,
        vault_source: vault_resolution.source,
        vault_profile: KnowledgeSDK.profile_for(vault_root) || "generic",
        ruby_version: RUBY_VERSION,
        schemas: registry.keys.length,
        predicates: relationships.predicates.length,
        capabilities: agent_gateway.registry.size,
        structured_datasets: dataset_status,
        validator_output: [stdout, stderr].join.strip
      )
      status.success? && dataset_status.fetch(:status) == "ok" ? 0 : 1
    end

    def stats_command
      counts = Hash.new(0)
      statuses = Hash.new(0)
      repository.each_record do |record|
        counts[record.type] += 1
        statuses[record.data["record_status"]] += 1
      end
      emit_json(total: counts.values.sum, by_type: counts.sort.to_h, by_status: statuses.sort.to_h)
      0
    end

    def search_command
      query = @argv.join(" ").strip
      raise InvalidIntent, "search expects a query" if query.empty?

      dataset_result = StructuredDataset::Search.new(engine: dataset_engine).query(query)
      if dataset_result
        emit_json(dataset_result)
        return 0
      end

      agent = AgentPlatform::AgentIdentity.new(
        id: @options[:actor_id].to_s.empty? ? "local-cli-search" : @options[:actor_id],
        permissions: ["graph:read"], roles: ["local_reader"]
      )
      contract = agent_gateway.discover(agent: agent).find do |item|
        item.fetch("capability_id") == "kg.entities.search"
      end
      raise InvalidIntent, "entity search capability is unavailable" unless contract

      request = agent_gateway.issue_request(
        invocation_token: contract.fetch("invocation_token"), arguments: { query: query }
      )
      response = agent_gateway.execute(request: request, agent: agent)
      raise InvalidIntent, response.errors.first.fetch("message") unless response.success?

      emit_json(response.payload)
      0
    end

    def graph_command
      reference = @argv.shift
      entity = reference && repository.resolve(reference)
      edges = []
      repository.each_record do |record|
        next unless record.type == "relationship" && record.data["relationship_status"] == "asserted"

        data = record.data
        next if entity && data["subject_id"] != entity.id && data["object_id"] != entity.id

        predicate = if entity && data["object_id"] == entity.id
                      relationship_registry.inverse_for(data["predicate"])
                    else
                      data["predicate"]
                    end
        edges << {
          id: record.id,
          subject_id: data["subject_id"],
          predicate: predicate,
          canonical_predicate: data["predicate"],
          object_id: data["object_id"]
        }
      end
      emit_json(entity_id: entity&.id, edges: edges)
      0
    end

    def replay_command
      event_id = @argv.shift
      raise InvalidIntent, "replay expects an audit event ID" unless event_id

      event = engine.audit_log.find(event_id)
      raise InvalidIntent, "cannot replay a failed event" unless event["result"] == "success"

      emit_result(engine.execute(IntentFactory.build(event.fetch("intent"))))
      0
    end

    def gateway_command
      AgentPlatform::Adapters::CLI.new(
        gateway: agent_gateway, argv: @argv, out: @out, err: @err,
        agent: AgentPlatform.local_cli_identity(@options[:actor_id])
      ).run
    end

    def agent_gateway
      @agent_gateway ||= AgentPlatform.build(
        vault_root: vault_root, run_id: @options[:run_id], actor_id: @options[:actor_id],
        event_bus: orchestrator.event_bus, notification_store: orchestrator.notifications
      )
    end

    def dataset_engine
      @dataset_engine ||= StructuredDataset::Engine.new(
        vault_root: vault_root, run_id: @options[:run_id], actor_id: @options[:actor_id],
        event_bus: orchestrator.event_bus
      )
    end

    def dataset_health
      database = StructuredDataset::Database.new(vault_root: vault_root)
      version = database.migrate!
      storage_ids = []
      integrity = nil
      foreign_key_violations = []
      database.with_connection do |connection|
        storage_ids = database.datasets(connection).map { |item| item.fetch("dataset_id") }
        integrity = connection.get_first_value("PRAGMA quick_check")
        foreign_key_violations = connection.execute("PRAGMA foreign_key_check")
      end
      graph_datasets = dataset_engine.list
      graph_ids = graph_datasets.map { |item| item.fetch("dataset_id") }
      missing_storage = graph_datasets.reject { |item| item["storage_status"] == "ready" }.map { |item| item.fetch("dataset_id") }
      orphan_storage = storage_ids - graph_ids
      healthy = integrity == "ok" && foreign_key_violations.empty? && missing_storage.empty? && orphan_storage.empty?
      {
        status: healthy ? "ok" : "failed", sqlite_version: SQLite3::SQLITE_VERSION,
        schema_version: version, datasets: graph_ids.length, integrity: integrity,
        foreign_key_violations: foreign_key_violations.length,
        missing_storage: missing_storage, orphan_storage: orphan_storage, path: database.path.to_s
      }
    rescue StructuredDataset::Error => error
      { status: "failed", error: error.message }
    end

    def engine
      @engine ||= KnowledgeOrchestration::EngineEventBridge.new(
        event_bus: orchestrator.event_bus
      ).attach(Engine.new(
        vault_root: vault_root,
        run_id: @options[:run_id],
        actor_id: @options[:actor_id]
      ))
    end

    def orchestrator
      @orchestrator ||= KnowledgeOrchestration.build(
        vault_root: vault_root, run_id: @options[:run_id], actor_id: @options[:actor_id],
        threaded_workflows: false
      )
    end

    def repository
      @repository ||= Repository.new(vault_root: vault_root, registry: schema_registry)
    end

    def schema_registry
      @schema_registry ||= SchemaRegistry.new(vault_root: vault_root)
    end

    def relationship_registry
      @relationship_registry ||= RelationshipRegistry.new(vault_root: vault_root)
    end

    def vault_root
      vault_resolution.path
    end

    def vault_resolution
      @vault_resolution ||= KnowledgeSDK::VaultLocator.new(registry: registry).resolve(
        explicit: @options[:vault_root]
      )
    end

    def registry
      @registry ||= KnowledgeSDK::VaultRegistry.new(configuration: KnowledgeSDK.configuration)
    end

    def plugin_registry
      @plugin_registry ||= KnowledgeSDK::PluginRegistry.new
    end

    def run_validator
      validator = KnowledgeSDK.validator_path(vault_root)
      raise ValidationError, "SDK validator not found: #{validator}" unless validator.file?

      Open3.capture3({ "VAULT_ROOT" => vault_root.to_s }, RbConfig.ruby, validator.to_s)
    end

    def emit_result(result)
      emit_json(
        intent_type: result.intent_type,
        entity_ids: result.entity_ids,
        changed_paths: result.changed_paths,
        value: result.value,
        replayed: result.replayed,
        duration_ms: result.duration_ms,
        audit_id: result.audit_id
      )
    end

    def emit_json(value)
      @out.puts(JSON.pretty_generate(value))
    end

    def print_help(option_parser)
      @out.puts(option_parser)
      @out.puts("SDK: init, attach, detach, upgrade, migrate, version, id, vault, plugin")
      @out.puts("Knowledge: execute, validate, doctor, graph, stats, search, replay, dataset, activity, chat, observe, extract, proposal, intelligence, goal, plan, gateway, events, workflow, scheduler, notifications, cache")
      0
    end
  end
end
