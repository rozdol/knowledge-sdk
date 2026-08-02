# frozen_string_literal: true

require "json"
require "optparse"
require "pathname"

module KnowledgeExtraction
  class ObservationCLI
    def initialize(argv:, out:, err:, stdin:, vault_root:, gateway:, event_bus:, cache:,
                   actor_id: nil, clock: nil, pipeline: nil, snapshot_provider: nil)
      @argv = argv.dup
      @out = out
      @err = err
      @stdin = stdin
      @vault_root = Pathname.new(vault_root)
      @gateway = gateway
      @event_bus = event_bus
      @cache = cache
      @actor_id = actor_id
      @clock = clock || -> { Time.now }
      @pipeline = pipeline
      @snapshot_provider = snapshot_provider || lambda do
        KnowledgeIntelligence::GraphSnapshot.load(vault_root: @vault_root)
      end
      @json_requested = false
    end

    def run
      options, option_parser = parse_options
      if options[:help]
        @out.puts(option_parser)
        return 0
      end

      text = observation_text(options)
      envelope = ObservationEnvelope.new(
        text: text, source: options[:source], conversation: options[:conversation],
        message_id: options[:message_id], sender: options[:sender],
        timestamp: options[:timestamp], source_type: options[:source_type],
        sensitivity: options[:sensitivity], clock: @clock
      )
      classification = KnowledgeGraph::ChatIntentResolver.classifier.classify(
        envelope.text, envelope.gateway_arguments
      )
      result = if classification && classification.route == "dataset"
                 dataset_observation(envelope, classification)
               else
                 observation_pipeline.process(envelope)
               end
      if options[:json]
        @out.puts(JSON.pretty_generate(result.to_h(explain: options[:explain])))
      else
        @out.puts(HumanObservationRenderer.new.render(result, explain: options[:explain]))
      end
      0
    rescue OptionParser::ParseError, ArgumentError, NormalizationFailure, UnsupportedSource => error
      emit_error("invalid_observation", error.message)
      2
    rescue ObservationFailure, AgentPlatform::Error, KnowledgeOrchestration::Error => error
      emit_error("observation_failed", error.message)
      1
    end

    private

    def parse_options
      options = {
        source: "cli", sensitivity: "private", json: false,
        explain: false, stdin: false, help: false
      }
      parser = OptionParser.new do |option|
        option.banner = "Usage: kg observe (--text TEXT | --stdin | --file PATH) [options]"
        option.on("--text TEXT", "Natural-language observation") { |value| options[:text] = value }
        option.on("--stdin", "Read observation text from standard input") { options[:stdin] = true }
        option.on("--file PATH", "Read observation text from a file") { |value| options[:file] = value }
        option.on("--source NAME", "Originating system, such as telegram") { |value| options[:source] = value }
        option.on("--source-type TYPE", SourceDocument::TYPES.join(", ")) { |value| options[:source_type] = value }
        option.on("--conversation ID", "Stable conversation identifier") { |value| options[:conversation] = value }
        option.on("--message-id ID", "Stable source message identifier") { |value| options[:message_id] = value }
        option.on("--sender ID", "Source sender identifier") { |value| options[:sender] = value }
        option.on("--timestamp TIME", "ISO 8601 source timestamp") { |value| options[:timestamp] = value }
        option.on("--sensitivity LEVEL", ObservationEnvelope::SENSITIVITIES.join(", ")) do |value|
          options[:sensitivity] = value
        end
        option.on("--json", "Emit stable machine-readable JSON") do
          options[:json] = true
          @json_requested = true
        end
        option.on("--explain", "Show the pipeline stages executed") { options[:explain] = true }
        option.on("-h", "--help", "Show observe help") { options[:help] = true }
      end
      parser.parse!(@argv)
      raise OptionParser::InvalidOption, "unexpected arguments: #{@argv.join(' ')}" unless @argv.empty?

      [options, parser]
    end

    def observation_text(options)
      selected = [!options[:text].nil?, options[:stdin], !options[:file].nil?].count(true)
      unless selected == 1
        raise OptionParser::MissingArgument, "choose exactly one of --text, --stdin, or --file"
      end
      return options[:text] unless options[:text].nil?
      return @stdin.read if options[:stdin]

      Pathname.new(options.fetch(:file)).read
    rescue Errno::ENOENT, Errno::EACCES, Errno::EISDIR
      raise ArgumentError, "observation source file could not be read"
    end

    def observation_pipeline
      @pipeline ||= ObservationPipeline.new(
        gateway: @gateway,
        agent: AgentPlatform::AgentIdentity.new(
          id: @actor_id.to_s.empty? ? "kg-observe-cli" : @actor_id.to_s,
          permissions: %w[proposal:create proposal:read],
          roles: ["observation_client"],
          attributes: {
            "autonomous_execution" => false,
            "allowed_capabilities" => [
              ObservationPipeline::EXTRACTION_CAPABILITY,
              ObservationPipeline::VALIDATION_CAPABILITY
            ],
            "denied_capabilities" => ["kg.proposals.submit"]
          }
        ),
        event_bus: @event_bus,
        cache: @cache,
        proposal_store: ProposalStore.new(vault_root: @vault_root, clock: @clock),
        snapshot_provider: @snapshot_provider
      )
    end

    def dataset_observation(envelope, classification)
      trace_id = Support.stable_id("trace", envelope.observation_id)
      @event_bus.publish(
        type: "ObservationReceived", source: "kg.observe", payload: envelope.event_payload,
        correlation_id: envelope.observation_id, trace_id: trace_id
      )
      contract = @gateway.discover(agent: dataset_agent).find do |item|
        item.fetch("capability_id") == "kg.datasets.propose"
      end
      raise ObservationFailure, "Dataset proposal capability is unavailable under policy" unless contract

      request = @gateway.issue_request(
        invocation_token: contract.fetch("invocation_token"),
        arguments: envelope.gateway_arguments, trace_id: trace_id
      )
      response = @gateway.execute(request: request, agent: dataset_agent)
      unless response.success?
        error = response.errors.first || { "code" => "ExecutionFailed", "message" => "capability failed" }
        raise ObservationFailure, "#{error.fetch('code')}: #{error.fetch('message')}"
      end
      result = response.payload
      if result["status"] == "clarification_required"
        raise ObservationFailure, result.fetch("question")
      end

      @event_bus.publish(
        type: "ObservationCompleted", source: "kg.observe",
        payload: {
          "observation_id" => envelope.observation_id,
          "proposal_id" => result.fetch("proposal_id"), "status" => "ok"
        },
        correlation_id: envelope.observation_id, trace_id: trace_id
      )
      payload = {
        "status" => "ok", "observation_id" => envelope.observation_id,
        "events" => %w[ObservationReceived ProposalCreated ObservationCompleted],
        "summary" => {
          "entities_detected" => 0, "proposals_created" => 1,
          "approval_required" => true
        },
        "proposals" => [{
          "id" => result.fetch("proposal_id"), "type" => "knowledge_update",
          "status" => "pending_approval"
        }],
        "cache" => { "artifacts_created" => [] }
      }
      ObservationResult.new(
        payload: payload, detected: [classification.intent],
        stages: ["Intent classified", "Dataset proposal generated", "Approval required"]
      )
    end

    def dataset_agent
      @dataset_agent ||= AgentPlatform::AgentIdentity.new(
        id: @actor_id.to_s.empty? ? "kg-observe-cli" : @actor_id.to_s,
        permissions: ["proposal:create"], roles: ["observation_client"],
        attributes: {
          "autonomous_execution" => false,
          "allowed_capabilities" => ["kg.datasets.propose"],
          "denied_capabilities" => ["kg.proposals.submit"]
        }
      )
    end

    def emit_error(code, message)
      payload = { status: "error", error: { code: code, message: message.to_s } }
      if @json_requested
        @out.puts(JSON.pretty_generate(payload))
      else
        @err.puts(JSON.generate(payload))
      end
    end
  end

  class HumanObservationRenderer
    def render(result, explain: false)
      payload = result.payload
      lines = ["Observation accepted.", "", "Detected:"]
      lines.concat(result.detected.empty? ? ["• None"] : result.detected.map { |item| "• #{item}" })
      lines.concat(["", "Generated:"])
      payload.fetch("proposals").each { |proposal| lines << "Proposal #{proposal.fetch('id')}" }
      if payload.fetch("status") == "clarification_required"
        lines.concat(["", payload.fetch("question")])
        payload.fetch("options").each do |option|
          lines << "• #{option.fetch('display_name')} (#{option.fetch('entity_id')})"
        end
      end
      lines << ""
      lines << (payload.fetch("summary").fetch("approval_required") ? "Approval required." : "No approval is currently required.")
      lines << ""
      lines << "No knowledge has been modified."
      if explain
        lines.concat(["", "Pipeline:"])
        lines.concat(result.stages.map { |stage| "✓ #{stage}" })
      end
      lines.join("\n")
    end
  end
end
