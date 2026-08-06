# frozen_string_literal: true

require "json"
require "optparse"

module KnowledgeCapture
  class CLI
    def initialize(argv:, out:, err:, vault_root:, engine:, event_bus: nil,
                   proposal_store: nil, clock: nil)
      @argv = argv.dup
      @out = out
      @err = err
      @vault_root = vault_root
      @engine = engine
      @event_bus = event_bus
      @clock = clock || -> { Time.now }
      @store = Store.new(vault_root: vault_root)
      @proposal_store = proposal_store || KnowledgeExtraction::ProposalStore.new(vault_root: vault_root, clock: @clock)
    end

    def run
      action = @argv.shift || "list"
      case action
      when "list" then list
      when "show" then show
      when "latest" then latest
      when "search" then search
      when "review" then review
      when "archive" then archive
      when "promote" then promote
      when "help", "--help", "-h" then help
      else raise InvalidCapture, "unknown capture command #{action.inspect}"
      end
      0
    end

    private

    def list
      options = common_options
      OptionParser.new do |parser|
        common_flags(parser, options)
        parser.on("--status STATUS", Capture::STATUSES.join(", ")) { |value| options[:status] = value }
        parser.on("--kind KIND", Capture::KINDS.join(", ")) { |value| options[:kind] = value }
        parser.on("--limit N", Integer, "Maximum results") { |value| options[:limit] = value }
      end.parse!(@argv)
      raise InvalidCapture, "unexpected arguments: #{@argv.join(' ')}" unless @argv.empty?
      captures = @store.all.reverse
      captures = captures.select { |capture| capture.status == options[:status] } if options[:status]
      captures = captures.select { |capture| capture.kind == options[:kind] } if options[:kind]
      captures = captures.first(options[:limit])
      emit_collection(captures, options, heading: options[:status] == "inbox" ? "Knowledge Inbox" : "Captures")
    end

    def show
      reference = @argv.shift || raise(InvalidCapture, "capture show expects a title or ID")
      options = common_options
      OptionParser.new { |parser| common_flags(parser, options) }.parse!(@argv)
      raise InvalidCapture, "unexpected arguments: #{@argv.join(' ')}" unless @argv.empty?
      capture = @store.find(reference)
      emit_capture(capture, options)
    end

    def latest
      options = common_options
      status = nil
      OptionParser.new do |parser|
        common_flags(parser, options)
        parser.on("--status STATUS", Capture::STATUSES.join(", ")) { |value| status = value }
      end.parse!(@argv)
      capture = @store.latest(status: status)
      raise CaptureNotFound, "no captures found" unless capture

      emit_capture(capture, options)
    end

    def search
      options = common_options.merge(limit: 25, status: nil, kind: nil)
      OptionParser.new do |parser|
        common_flags(parser, options)
        parser.on("--status STATUS", Capture::STATUSES.join(", ")) { |value| options[:status] = value }
        parser.on("--kind KIND", Capture::KINDS.join(", ")) { |value| options[:kind] = value }
        parser.on("--limit N", Integer, "Maximum results") { |value| options[:limit] = value }
      end.parse!(@argv)
      query = @argv.join(" ").strip
      result = Search.new(vault_root: @vault_root, clock: @clock).query(
        query, limit: options[:limit], include_ids: options[:ids],
        status: options[:status], kind: options[:kind]
      )
      if options[:json]
        @out.puts(JSON.pretty_generate(result))
      else
        @out.puts("Capture search: #{result.fetch('query')}")
        result.fetch("matches").each { |item| @out.puts(human_line(item)) }
        @out.puts("#{result.fetch('count')} result(s)")
      end
    end

    def review
      reference, options = mutation_options("capture review")
      capture = @store.find(reference)
      result = @engine.execute(KnowledgeGraph::ReviewCapture.new(capture_id: capture.id))
      emit_mutation(result, capture, options, "reviewed")
    end

    def archive
      reference, options = mutation_options("capture archive")
      capture = @store.find(reference)
      result = @engine.execute(KnowledgeGraph::ArchiveCapture.new(capture_id: capture.id))
      emit_mutation(result, capture, options, "archived")
    end

    def promote
      reference = @argv.shift || raise(PromotionError, "capture promote expects a title or ID")
      options = common_options.merge(target_kind: nil, target_ids: [], attributes: {}, entity_type: nil)
      OptionParser.new do |parser|
        common_flags(parser, options)
        parser.on("--to KIND", PromotionProposalBuilder::TARGET_KINDS.join(", ")) { |value| options[:target_kind] = value }
        parser.on("--target ID", "Promote to an existing canonical target") { |value| options[:target_ids] << value }
        parser.on("--entity-type TYPE", "Entity schema for entity promotion") { |value| options[:entity_type] = value }
        parser.on("--attributes JSON", "Target Intent attributes") do |value|
          parsed = JSON.parse(value)
          raise PromotionError, "promotion attributes must be an object" unless parsed.is_a?(Hash)
          options[:attributes] = parsed
        end
      end.parse!(@argv)
      raise PromotionError, "--to is required" unless options[:target_kind]
      capture = @store.find(reference)
      result = PromotionProposalBuilder.new(
        vault_root: @vault_root, proposal_store: @proposal_store,
        event_bus: @event_bus, clock: @clock
      ).create(
        capture: capture, target_kind: options[:target_kind],
        target_ids: options[:target_ids], attributes: options[:attributes],
        entity_type: options[:entity_type]
      )
      if options[:json]
        @out.puts(JSON.pretty_generate(result))
      else
        @out.puts("Promotion proposal #{result.fetch('proposal_id')} is awaiting exact approval.")
        @out.puts("Target: #{result.fetch('target_kind')}")
      end
    end

    def mutation_options(label)
      reference = @argv.shift || raise(InvalidCapture, "#{label} expects a title or ID")
      options = common_options
      OptionParser.new { |parser| common_flags(parser, options) }.parse!(@argv)
      [reference, options]
    end

    def common_options
      { json: false, ids: false, limit: 100 }
    end

    def common_flags(parser, options)
      parser.on("--json", "Emit stable JSON") { options[:json] = true }
      parser.on("--ids", "Include immutable Capture IDs") { options[:ids] = true }
    end

    def emit_collection(captures, options, heading:)
      if options[:json]
        @out.puts(JSON.pretty_generate(
          "status" => "ok", "captures" => captures.map do |capture|
            capture.public_h(include_id: options[:ids], include_body: false)
          end, "count" => captures.length
        ))
      else
        @out.puts(heading)
        captures.each do |capture|
          item = capture.public_h(include_id: options[:ids], include_body: false)
          @out.puts(human_line(item))
        end
        @out.puts("#{captures.length} capture(s)")
      end
    end

    def emit_capture(capture, options)
      if options[:json]
        @out.puts(JSON.pretty_generate(
          "status" => "ok", "capture" => capture.public_h(include_id: options[:ids])
        ))
      else
        @out.puts("#{capture.kind.capitalize}: #{capture.title}")
        @out.puts("Status: #{capture.status}; review: #{capture.review_state}; captured: #{capture.captured_at.iso8601}")
        @out.puts("ID: #{capture.id}") if options[:ids]
        @out.puts
        @out.puts(capture.body)
      end
    end

    def emit_mutation(result, capture, options, verb)
      payload = {
        "status" => "ok", "action" => "knowledge.capture.#{verb == 'reviewed' ? 'review' : 'archive'}",
        "title" => capture.title, "capture_status" => verb,
        "replayed" => result.replayed, "audit_id" => result.audit_id
      }
      payload["capture_id"] = capture.id if options[:ids]
      options[:json] ? @out.puts(JSON.pretty_generate(payload)) : @out.puts("#{capture.title} was #{verb}.")
    end

    def human_line(item)
      id = item["capture_id"] ? " [#{item['capture_id']}]" : ""
      "- #{item.fetch('kind')}: #{item.fetch('title')} (#{item.fetch('status')})#{id}"
    end

    def help
      @out.puts("Usage: kg capture list|show|latest|search|review|promote|archive [options]")
      @out.puts("Use --ids only when immutable Capture IDs are needed.")
    end
  end
end
