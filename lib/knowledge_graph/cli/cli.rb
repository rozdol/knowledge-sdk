# frozen_string_literal: true

require "json"
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
      @options = { vault_root: Dir.pwd, run_id: ENV["KG_RUN_ID"], actor_id: ENV["KG_ACTOR_ID"] }
    end

    def run
      parser.order!(@argv)
      command = @argv.shift
      return print_help(parser) unless command

      case command
      when "execute" then execute_command
      when "validate" then validate_command
      when "doctor" then doctor_command
      when "graph" then graph_command
      when "stats" then stats_command
      when "search" then search_command
      when "replay" then replay_command
      when "gateway" then gateway_command
      when "intelligence" then KnowledgeIntelligence::CLI.new(
        argv: @argv, out: @out, err: @err, vault_root: vault_root
      ).run
      when "goal", "plan" then KnowledgePlanning::CLI.new(
        group: command, argv: @argv, out: @out, err: @err, stdin: @stdin,
        vault_root: vault_root
      ).run
      when "extract", "proposal" then KnowledgeExtraction::CLI.new(
        command: command, argv: @argv, out: @out, err: @err,
        vault_root: vault_root, run_id: @options[:run_id], actor_id: @options[:actor_id]
      ).run
      when "help", "--help", "-h" then print_help(parser)
      else
        raise InvalidIntent, "unknown command #{command.inspect}"
      end
    rescue OptionParser::ParseError, JSON::ParserError, InvalidIntent => error
      @err.puts(JSON.generate(error: error.message))
      2
    rescue KnowledgeGraph::Error => error
      @err.puts(JSON.generate(error: error.message, error_class: error.class.name))
      1
    rescue KnowledgeExtraction::Error => error
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
        options.on("--run-id RUN_ID", "Agent run ID") { |value| @options[:run_id] = value }
        options.on("--actor-id ACTOR_ID", "Future actor/audit identifier") { |value| @options[:actor_id] = value }
        options.on("-h", "--help", "Show help") { @options[:help] = true }
      end
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
      emit_json(
        status: status.success? ? "ok" : "failed",
        ruby_version: RUBY_VERSION,
        schemas: registry.keys.length,
        predicates: relationships.predicates.length,
        capabilities: agent_gateway.registry.size,
        validator_output: [stdout, stderr].join.strip
      )
      status.success? ? 0 : 1
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
        vault_root: vault_root, run_id: @options[:run_id], actor_id: @options[:actor_id]
      )
    end

    def engine
      @engine ||= Engine.new(
        vault_root: vault_root,
        run_id: @options[:run_id],
        actor_id: @options[:actor_id]
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
      @vault_root ||= Pathname.new(@options[:vault_root]).expand_path
    end

    def run_validator
      validator = vault_root.join("_System/Tools/validate_vault.rb")
      raise ValidationError, "required vault validator not found: #{validator}" unless validator.file?

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
      @out.puts("Commands: execute, validate, doctor, graph, stats, search, replay, extract, proposal, intelligence, goal, plan, gateway")
      0
    end
  end
end
