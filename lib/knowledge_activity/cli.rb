# frozen_string_literal: true

require "json"
require "optparse"

module KnowledgeActivity
  class CLI
    COMMANDS = %w[latest recent today yesterday since between search explain undo restore diff].freeze

    def initialize(argv:, out:, err:, vault_root:, event_bus: nil, cache: nil, clock: nil)
      @argv = argv.dup
      @out = out
      @err = err
      @options = { json: false, limit: nil, actor: nil, source: nil, latest: false }
      event_store = event_bus&.store
      @timeline = Timeline.new(
        vault_root: vault_root, event_store: event_store, event_bus: event_bus,
        cache: cache, clock: clock
      )
    end

    def run
      command = @argv.shift
      raise InvalidActivityQuery, "activity expects one of: #{COMMANDS.join(', ')}" unless COMMANDS.include?(command)

      parser.parse!(@argv)
      result = dispatch(command)
      @out.puts(JSON.pretty_generate(result))
      0
    rescue OptionParser::ParseError, InvalidActivityQuery, ActivityNotFound, ReversalUnavailable => error
      @err.puts(JSON.generate(status: "error", error: error.message))
      2
    rescue KnowledgeGraph::Error, KnowledgeExtraction::Error, KnowledgeOrchestration::Error => error
      @err.puts(JSON.generate(status: "error", error: error.message, error_class: error.class.name))
      1
    end

    private

    def parser
      @parser ||= OptionParser.new do |option|
        option.banner = "Usage: kg activity COMMAND [arguments] [options]"
        option.on("--json", "Emit stable JSON (JSON is the default)") { @options[:json] = true }
        option.on("--limit N", Integer, "Maximum activities") { |value| @options[:limit] = value }
        option.on("--actor ACTOR", "Filter by actor") { |value| @options[:actor] = value }
        option.on("--source SOURCE", "Filter by source") { |value| @options[:source] = value }
        option.on("--time TIME", "ISO 8601 lower bound") { |value| @options[:time] = value }
        option.on("--from VALUE", "Activity ID or ISO 8601 lower bound") { |value| @options[:from] = value }
        option.on("--to VALUE", "Activity ID or ISO 8601 upper bound") { |value| @options[:to] = value }
        option.on("--query QUERY", "Search text") { |value| @options[:query] = value }
        option.on("--latest", "Use the latest matching activity") { @options[:latest] = true }
        option.on("-h", "--help", "Show activity help") { @options[:help] = true }
      end
    end

    def dispatch(command)
      return help if @options[:help]

      case command
      when "latest"
        { status: "ok", activity: @timeline.latest(**filters)&.to_h }
      when "recent"
        list_result(@timeline.recent(limit: @options[:limit] || Timeline::DEFAULT_LIMIT, **filters))
      when "today"
        list_result(@timeline.today(limit: @options[:limit], **filters))
      when "yesterday"
        list_result(@timeline.yesterday(limit: @options[:limit], **filters))
      when "since"
        raise InvalidActivityQuery, "activity since requires --time" unless @options[:time]
        list_result(@timeline.since(time: @options[:time], limit: @options[:limit], **filters))
      when "between"
        raise InvalidActivityQuery, "activity between requires --from and --to" unless @options[:from] && @options[:to]
        list_result(@timeline.between(
          from_time: @options[:from], to_time: @options[:to], limit: @options[:limit], **filters
        ))
      when "search"
        query = @options[:query] || @argv.join(" ")
        list_result(@timeline.search(
          query: query, limit: @options[:limit] || Timeline::DEFAULT_LIMIT, **filters
        ))
      when "explain"
        @timeline.explain(selected_activity)
      when "undo", "restore"
        @timeline.create_proposal(selected_activity, operation: command)
      when "diff"
        from = @options[:from] || @argv.shift
        to = @options[:to] || @argv.shift
        raise InvalidActivityQuery, "activity diff requires FROM and TO activity IDs" unless from && to
        @timeline.diff(from: from, to: to, limit: @options[:limit], **filters)
      end
    end

    def selected_activity
      if @options[:latest]
        @timeline.latest(**filters) || raise(ActivityNotFound, "no matching activity exists")
      else
        reference = @argv.shift
        raise InvalidActivityQuery, "an activity ID or --latest is required" unless reference
        @timeline.find(reference)
      end
    end

    def list_result(activities)
      { status: "ok", activities: activities.map(&:to_h), count: activities.length }
    end

    def filters
      { actor: @options[:actor], source: @options[:source] }
    end

    def help
      { status: "ok", usage: parser.banner, commands: COMMANDS }
    end
  end
end
