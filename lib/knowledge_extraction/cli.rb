# frozen_string_literal: true

require "json"
require "optparse"
require "pathname"

module KnowledgeExtraction
  class CLI
    SOURCE_COMMANDS = {
      "text" => "text", "chat" => "chat", "meeting-notes" => "meeting-notes",
      "email-text" => "email-text", "transcript" => "transcript",
      "ocr-text" => "ocr-text", "pdf-text" => "pdf-text"
    }.freeze

    def initialize(command:, argv:, out:, err:, vault_root:, run_id:, actor_id:)
      @command = command
      @argv = argv.dup
      @out = out
      @err = err
      @vault_root = Pathname.new(vault_root)
      @run_id = run_id
      @actor_id = actor_id
    end

    def run
      @command == "extract" ? extract_command : proposal_command
    rescue OptionParser::ParseError, JSON::ParserError, ArgumentError => error
      @err.puts(JSON.generate(error: error.message))
      2
    end

    private

    def extract_command
      subtype = @argv.shift
      raise UnsupportedSource, "extract expects a source type or evaluate" unless subtype
      return evaluate_command if subtype == "evaluate"

      options = {
        dry_run: false, language: "und", captured_at: nil, format: "summary",
        provider: subtype == "replay" ? "replay" : "deterministic"
      }
      parser = OptionParser.new do |option|
        option.banner = "Usage: kg extract TYPE --file PATH [options]"
        option.on("--file PATH", "Text source file") { |value| options[:file] = value }
        option.on("--fixture PATH", "Replay provider fixture") { |value| options[:fixture] = value }
        option.on("--language CODE", "Source language") { |value| options[:language] = value }
        option.on("--captured-at TIME", "ISO 8601 capture time") { |value| options[:captured_at] = value }
        option.on("--external-id ID", "Stable external source ID") { |value| options[:external_id] = value }
        option.on("--source-uri URI", "Source URI") { |value| options[:source_uri] = value }
        option.on("--title TITLE", "Source title") { |value| options[:title] = value }
        option.on("--provider NAME", "deterministic or replay") { |value| options[:provider] = value }
        option.on("--format FORMAT", "summary, json, or markdown") { |value| options[:format] = value }
        option.on("--dry-run", "Do not persist proposal artifacts") { options[:dry_run] = true }
      end
      parser.parse!(@argv)
      if subtype == "replay"
        run_replay_extract(options)
      else
        source_type = SOURCE_COMMANDS[subtype]
        raise UnsupportedSource, "unsupported extraction source #{subtype.inspect}" unless source_type
        run_text_extract(source_type, options)
      end
    end

    def run_text_extract(source_type, options)
      raise UnsupportedSource, "--file is required" unless options[:file]
      content = Pathname.new(options[:file]).read
      provider = provider_for(options, nil)
      proposal = pipeline(provider).process(
        content, source_type: source_type, language: options[:language],
        captured_at: options[:captured_at], external_id: options[:external_id],
        source_uri: options[:source_uri], title: options[:title], persist: !options[:dry_run]
      )
      emit_proposal(proposal, options, persisted: !options[:dry_run])
      0
    rescue Errno::ENOENT, Errno::EACCES => error
      raise UnsupportedSource, "source file could not be read: #{error.message}"
    end

    def run_replay_extract(options)
      raise ProviderFailure, "--fixture is required for replay" unless options[:fixture]
      fixture = JSON.parse(Pathname.new(options[:fixture]).read)
      source = fixture.fetch("source")
      content = source.fetch("content")
      source_type = source.fetch("source_type", "text")
      provider = ReplayExtractionProvider.new(fixture)
      proposal = pipeline(provider).process(
        content, source_type: source_type, language: source.fetch("language", "und"),
        source_id: source["source_id"],
        captured_at: source["captured_at"], external_id: source["external_id"],
        source_uri: source["source_uri"], title: source["title"],
        metadata: source.fetch("metadata", {}), persist: !options[:dry_run]
      )
      emit_proposal(proposal, options, persisted: !options[:dry_run])
      0
    rescue Errno::ENOENT, Errno::EACCES => error
      raise ProviderFailure, "replay fixture could not be read: #{error.message}"
    end

    def proposal_command
      action = @argv.shift
      raise ProposalNotFound, "proposal expects show, export, validate, approve, or submit" unless action
      proposal_id = @argv.shift
      raise ProposalNotFound, "proposal ID is required" unless proposal_id

      case action
      when "show"
        @out.puts(MarkdownProposalRenderer.new.render(store.load(proposal_id)))
      when "export"
        proposal_export(proposal_id)
      when "validate"
        proposal = store.load(proposal_id)
        ProposalValidator.new.validate!(proposal)
        @out.puts(JSON.pretty_generate(proposal_id: proposal_id, status: "valid"))
      when "approve"
        proposal_approve(proposal_id)
      when "submit"
        proposal_submit(proposal_id)
      else
        raise ProposalNotFound, "unknown proposal action #{action.inspect}"
      end
      0
    end

    def proposal_export(proposal_id)
      options = { format: "json" }
      OptionParser.new do |option|
        option.on("--format FORMAT", "json or markdown") { |value| options[:format] = value }
      end.parse!(@argv)
      proposal = store.load(proposal_id)
      case options[:format]
      when "json" then @out.puts(JSON.pretty_generate(proposal))
      when "markdown" then @out.puts(MarkdownProposalRenderer.new.render(proposal))
      else raise ArgumentError, "format must be json or markdown"
      end
    end

    def proposal_approve(proposal_id)
      options = { intent_ids: [], all: false, actor_id: @actor_id }
      OptionParser.new do |option|
        option.on("--intent ID", "Approve one planned Intent") { |value| options[:intent_ids] << value }
        option.on("--all", "Approve every unblocked planned Intent") { options[:all] = true }
        option.on("--actor ID", "Approving human actor ID") { |value| options[:actor_id] = value }
      end.parse!(@argv)
      proposal = store.load(proposal_id)
      if options[:all]
        options[:intent_ids] = proposal.fetch("planned_intents").reject do |item|
          !item.fetch("blocked_reasons", []).empty?
        end.map { |item| item.fetch("planned_intent_id") }
      end
      raise ApprovalSubmissionFailure, "select --intent ID or --all" if options[:intent_ids].empty?

      @out.puts(JSON.pretty_generate(store.approve(
        proposal_id: proposal_id, intent_ids: options[:intent_ids], actor_id: options[:actor_id]
      )))
    end

    def proposal_submit(proposal_id)
      options = { dry_run: false }
      OptionParser.new { |option| option.on("--dry-run") { options[:dry_run] = true } }.parse!(@argv)
      result = ProposalSubmitter.new(engine: engine, store: store).submit(proposal_id, dry_run: options[:dry_run])
      @out.puts(JSON.pretty_generate(result))
    end

    def evaluate_command
      options = { provider: "replay", dataset: default_dataset }
      OptionParser.new do |option|
        option.on("--provider NAME", "replay") { |value| options[:provider] = value }
        option.on("--dataset PATH", "Golden dataset") { |value| options[:dataset] = value }
      end.parse!(@argv)
      raise ProviderFailure, "offline evaluation supports replay only" unless options[:provider] == "replay"

      report = EvaluationRunner.new(
        dataset_path: options[:dataset], graph_reader: graph_reader,
        reports_dir: @vault_root.join("_System/KnowledgeGraph/docs/Knowledge Extraction/Reports")
      ).run
      @out.puts(JSON.pretty_generate(report))
      0
    end

    def provider_for(options, fixture)
      case options[:provider]
      when "deterministic" then DeterministicExtractionProvider.new
      when "replay" then ReplayExtractionProvider.new(fixture || options.fetch(:fixture))
      else raise ProviderFailure, "unknown provider #{options[:provider].inspect}"
      end
    end

    def pipeline(provider)
      configuration = Configuration.new(
        provider_name: provider.name,
        allowed_entity_types: graph_reader.entity_types,
        allowed_predicates: graph_reader.predicates
      )
      KnowledgeExtractionPipeline.new(
        graph_reader: graph_reader, provider: provider, configuration: configuration,
        proposal_store: store
      )
    end

    def emit_proposal(proposal, options, persisted:)
      case options[:format]
      when "json" then @out.write(proposal.canonical_json)
      when "markdown" then @out.puts(MarkdownProposalRenderer.new.render(proposal))
      when "summary"
        @out.puts(ConciseProposalRenderer.new.render(proposal))
        @out.puts("Artifact: #{store.path_for(proposal.proposal_id)}") if persisted
      else raise ArgumentError, "format must be summary, json, or markdown"
      end
    end

    def graph_reader
      @graph_reader ||= KnowledgeGraph::GraphReader.new(vault_root: @vault_root)
    end

    def store
      @store ||= ProposalStore.new(vault_root: @vault_root)
    end

    def engine
      @engine ||= KnowledgeGraph::Engine.new(
        vault_root: @vault_root, run_id: @run_id, actor_id: @actor_id
      )
    end

    def default_dataset
      @vault_root.join("_System/KnowledgeGraph/test/knowledge_extraction/golden/cases.json").to_s
    end
  end
end
