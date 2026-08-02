# frozen_string_literal: true

require "json"
require "optparse"
require "pathname"
require "stringio"

module KnowledgeGraph
  class ChatCLI
    def initialize(argv:, out:, err:, stdin:, vault_root:, gateway:, event_bus:, cache:, actor_id: nil)
      @argv = argv.dup
      @out = out
      @err = err
      @stdin = stdin
      @vault_root = Pathname.new(vault_root)
      @gateway = gateway
      @event_bus = event_bus
      @cache = cache
      @actor_id = actor_id
      @json_requested = false
    end

    def run
      options, option_parser = parse_options
      return emit_help(option_parser, json: options[:json]) if options[:help]

      text = chat_text(options)
      response = router.route(
        text, explain: options[:explain], context: dataset_arguments(text, options)
      ) do
        observe(text, options)
      end
      emit(response, json: options[:json])
      response["status"] == "error" ? 1 : 0
    rescue OptionParser::ParseError, ArgumentError, KnowledgeExtraction::NormalizationFailure,
           KnowledgeExtraction::UnsupportedSource => error
      emit_error("invalid_chat", error.message)
      2
    rescue ChatError, AgentPlatform::Error, KnowledgeExtraction::Error,
           KnowledgeOrchestration::Error => error
      emit_error("chat_failed", error.message)
      1
    end

    private

    def parse_options
      options = {
        source: "cli", sensitivity: "private", json: false,
        explain: false, stdin: false, help: false
      }
      parser = OptionParser.new do |option|
        option.banner = "Usage: kg chat (--text TEXT | --stdin | --file PATH) [options]"
        option.on("--text TEXT", "Natural-language message") { |value| options[:text] = value }
        option.on("--stdin", "Read message text from standard input") { options[:stdin] = true }
        option.on("--file PATH", "Read message text from a file") { |value| options[:file] = value }
        option.on("--source NAME", "Originating system, such as telegram") { |value| options[:source] = value }
        option.on("--source-type TYPE", KnowledgeExtraction::SourceDocument::TYPES.join(", ")) do |value|
          options[:source_type] = value
        end
        option.on("--conversation ID", "Stable conversation identifier") { |value| options[:conversation] = value }
        option.on("--message-id ID", "Stable source message identifier") { |value| options[:message_id] = value }
        option.on("--sender ID", "Source sender identifier") { |value| options[:sender] = value }
        option.on("--timestamp TIME", "ISO 8601 source timestamp") { |value| options[:timestamp] = value }
        option.on("--sensitivity LEVEL", KnowledgeExtraction::ObservationEnvelope::SENSITIVITIES.join(", ")) do |value|
          options[:sensitivity] = value
        end
        option.on("--json", "Emit stable machine-readable JSON") do
          options[:json] = true
          @json_requested = true
        end
        option.on("--explain", "Show safe routing diagnostics") { options[:explain] = true }
        option.on("-h", "--help", "Show chat help") { options[:help] = true }
      end
      parser.parse!(@argv)
      raise OptionParser::InvalidOption, "unexpected arguments: #{@argv.join(' ')}" unless @argv.empty?

      [options, parser]
    end

    def chat_text(options)
      selected = [!options[:text].nil?, options[:stdin], !options[:file].nil?].count(true)
      unless selected == 1
        raise OptionParser::MissingArgument, "choose exactly one of --text, --stdin, or --file"
      end
      return options[:text] unless options[:text].nil?
      return @stdin.read if options[:stdin]

      Pathname.new(options.fetch(:file)).read
    rescue Errno::ENOENT, Errno::EACCES, Errno::EISDIR
      raise ArgumentError, "chat source file could not be read"
    end

    def observe(text, options)
      output = StringIO.new
      errors = StringIO.new
      arguments = ["--text", text, "--source", options.fetch(:source),
                   "--sensitivity", options.fetch(:sensitivity), "--json"]
      {
        source_type: "--source-type", conversation: "--conversation",
        message_id: "--message-id", sender: "--sender", timestamp: "--timestamp"
      }.each do |key, flag|
        arguments.concat([flag, options[key]]) if options[key]
      end
      arguments << "--explain" if options[:explain]
      status = KnowledgeExtraction::ObservationCLI.new(
        argv: arguments, out: output, err: errors, stdin: StringIO.new,
        vault_root: @vault_root, gateway: @gateway,
        event_bus: @event_bus, cache: @cache, actor_id: @actor_id
      ).run
      @err.write(errors.string) unless errors.string.empty?
      payload = JSON.parse(output.string)
      if status != 0 && payload["status"] != "error"
        raise ChatError, "observation route failed without a structured error"
      end
      payload
    rescue JSON::ParserError
      raise ChatError, "observation route returned invalid JSON"
    end

    def dataset_arguments(text, options)
      KnowledgeExtraction::ObservationEnvelope.new(
        text: text, source: options.fetch(:source), conversation: options[:conversation],
        message_id: options[:message_id], sender: options[:sender], timestamp: options[:timestamp],
        source_type: options[:source_type], sensitivity: options.fetch(:sensitivity)
      ).gateway_arguments
    end

    def router
      @router ||= ChatRouter.new(gateway: @gateway, actor_id: @actor_id)
    end

    def emit(response, json:)
      if json
        @out.puts(JSON.pretty_generate(response))
      else
        @out.puts(HumanChatRenderer.new.render(response))
      end
    end

    def emit_help(parser, json:)
      if json
        @out.puts(JSON.pretty_generate("status" => "ok", "result" => { "help" => parser.to_s }))
      else
        @out.puts(parser)
      end
      0
    end

    def emit_error(code, message)
      payload = { "status" => "error", "error" => { "code" => code, "message" => message.to_s } }
      if @json_requested
        @out.puts(JSON.pretty_generate(payload))
      else
        @err.puts(JSON.generate(payload))
      end
    end
  end

  class HumanChatRenderer
    def render(response)
      lines = ["route: #{response['route'] || 'none'}"]
      if response["status"] == "error"
        error = response.fetch("error")
        lines << "error: #{error.fetch('message')}"
      elsif response["status"] == "clarification_required"
        clarification = response.fetch("clarification")
        lines << clarification.fetch("question")
        Array(clarification["options"]).each do |option|
          lines << "- #{option['display_name']} (#{option['entity_id']})"
        end
      else
        lines << JSON.pretty_generate(response.fetch("result"))
      end
      if response["explain"]
        lines << "reason: #{response.dig('explain', 'reason')}"
        lines << "capability: #{response.dig('explain', 'capability') || 'none'}"
      end
      lines.join("\n")
    end
  end
end
