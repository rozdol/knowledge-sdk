# frozen_string_literal: true

require "json"
require "optparse"

module KnowledgeAnalysis
  class CLI
    def initialize(argv:, out:, err:, stdin:, vault_root:, dataset_engine: nil,
                   event_bus: nil, cache: nil, clock: nil)
      @argv = argv.dup
      @out = out
      @err = err
      @stdin = stdin
      @vault_root = vault_root
      @dataset_engine = dataset_engine
      @event_bus = event_bus
      @cache = cache
      @clock = clock
      @json = false
    end

    def run
      options = { propose_recommendations: false }
      parser = OptionParser.new do |item|
        item.banner = "Usage: kg analyze QUESTION [options]"
        item.on("--from TIME", "ISO 8601 lower time bound") { |value| options[:from] = value }
        item.on("--to TIME", "ISO 8601 upper time bound") { |value| options[:to] = value }
        item.on("--as-of DATE", "Analysis date") { |value| options[:as_of] = value }
        item.on("--propose-recommendations", "Persist review-only Recommendation Proposal") do
          options[:propose_recommendations] = true
        end
        item.on("--json", "Emit the stable machine-readable contract") { @json = true }
        item.on("-h", "--help", "Show analyze help") { options[:help] = true }
      end
      parser.parse!(@argv)
      if options[:help]
        @out.puts(parser)
        return 0
      end
      question = @argv.join(" ").strip
      question = @stdin.read.to_s.strip if question.empty? && !@stdin.tty?
      raise InvalidAnalysis, "analyze expects a question" if question.empty?

      result = engine.analyze(
        question, from: options[:from], to: options[:to], as_of: options[:as_of],
        propose_recommendations: options[:propose_recommendations]
      )
      @json ? @out.puts(JSON.pretty_generate(result)) : render(result.fetch("analysis"))
      0
    rescue OptionParser::ParseError, KnowledgeAnalysis::Error, ArgumentError => error
      payload = { "status" => "error", "error" => { "code" => error.class.name.split("::").last, "message" => error.message } }
      @json ? @out.puts(JSON.pretty_generate(payload)) : @err.puts(JSON.generate(payload))
      2
    end

    private

    def engine
      @engine ||= Engine.new(
        vault_root: @vault_root, dataset_engine: @dataset_engine,
        event_bus: @event_bus, cache: @cache, clock: @clock
      )
    end

    def render(analysis)
      @out.puts(analysis.fetch("summary"))
      @out.puts("Confidence: #{analysis.fetch('confidence')}")
      factors = analysis.fetch("possible_factors")
      if factors.empty?
        @out.puts("Possible contributing factors: none met the evidence threshold.")
      else
        @out.puts("Possible contributing factors:")
        factors.each do |factor|
          @out.puts("- #{factor.fetch('label')}: #{factor.fetch('association')} (confidence #{factor.fetch('confidence')})")
        end
      end
      unless analysis.fetch("limitations").empty?
        @out.puts("Limitations:")
        analysis.fetch("limitations").each { |item| @out.puts("- #{item}") }
      end
    end
  end
end
