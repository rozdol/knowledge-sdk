# frozen_string_literal: true

require "json"
require "optparse"
require "pathname"

module StructuredDataset
  class CLI
    COMMANDS = %w[create list describe insert update delete query export import stats explain migrate].freeze

    def initialize(argv:, out:, err:, vault_root:, run_id: nil, actor_id: nil, event_bus: nil)
      @argv = argv.dup
      @out = out
      @err = err
      @vault_root = Pathname.new(vault_root).expand_path
      @run_id = run_id
      @actor_id = actor_id
      @event_bus = event_bus
      @json = false
    end

    def run
      command = @argv.shift
      return help unless command
      raise OptionParser::InvalidArgument, "unknown dataset command #{command.inspect}" unless COMMANDS.include?(command)

      result = send("#{command}_command")
      emit(result)
      0
    rescue OptionParser::ParseError, JSON::ParserError, ArgumentError, StructuredDataset::Error => error
      payload = { "status" => "error", "error" => { "code" => error.class.name.split("::").last, "message" => error.message } }
      if @json
        @out.puts(JSON.pretty_generate(payload))
      else
        @err.puts(JSON.generate(payload))
      end
      2
    end

    private

    def create_command
      options = { json: false }
      parser = OptionParser.new do |item|
        item.banner = "Usage: kg dataset create NAME [options]"
        item.on("--schema JSON_OR_FILE", "Custom schema JSON or file") { |value| options[:schema] = value }
        item.on("--name NAME", "Canonical display name") { |value| options[:name] = value }
        item.on("--kind KIND", "Dataset kind") { |value| options[:kind] = value }
        item.on("--purpose TEXT", "Semantic purpose") { |value| options[:purpose] = value }
        item.on("--owner ENTITY_ID", "Canonical owner entity") { |value| options[:owner_id] = value }
        item.on("--sensitivity LEVEL", "normal, private, or restricted") { |value| options[:sensitivity] = value }
        json_option(item)
      end
      parser.parse!(@argv)
      reference = require_arguments!(parser, 1).first
      schema = options[:schema] && load_json_or_file(options[:schema])
      engine.create(
        reference, schema: schema, name: options[:name], purpose: options[:purpose],
        owner_id: options[:owner_id], sensitivity: options[:sensitivity], kind: options[:kind]
      )
    end

    def list_command
      parser = OptionParser.new { |item| item.banner = "Usage: kg dataset list [--json]"; json_option(item) }
      parser.parse!(@argv)
      require_arguments!(parser, 0)
      { "datasets" => engine.list }
    end

    def describe_command
      parser = OptionParser.new { |item| item.banner = "Usage: kg dataset describe DATASET [--json]"; json_option(item) }
      parser.parse!(@argv)
      engine.describe(require_arguments!(parser, 1).first)
    end

    def insert_command
      options = provenance_options("Usage: kg dataset insert DATASET [COLUMN=VALUE ...] [options]")
      parser = options.delete(:parser)
      parser.on("--data JSON_OR_FILE", "Row object") { |value| options[:data] = value }
      parser.parse!(@argv)
      raise OptionParser::MissingArgument, "dataset is required" if @argv.empty?

      reference = @argv.shift
      values = options[:data] ? load_json_or_file(options[:data]) : key_values(@argv)
      raise OptionParser::InvalidArgument, "row data must be an object" unless values.is_a?(Hash)

      engine.insert(reference, values, provenance(options))
    end

    def update_command
      options = provenance_options("Usage: kg dataset update DATASET ROW_ID [COLUMN=VALUE ...] [options]")
      parser = options.delete(:parser)
      parser.on("--data JSON_OR_FILE", "Partial row object") { |value| options[:data] = value }
      parser.parse!(@argv)
      raise OptionParser::MissingArgument, "dataset and row ID are required" if @argv.length < 2

      reference = @argv.shift
      row_id = @argv.shift
      values = options[:data] ? load_json_or_file(options[:data]) : key_values(@argv)
      raise OptionParser::InvalidArgument, "row data must be an object" unless values.is_a?(Hash)

      engine.update(reference, row_id, values, provenance(options))
    end

    def delete_command
      options = provenance_options("Usage: kg dataset delete DATASET ROW_ID [options]")
      parser = options.delete(:parser)
      parser.parse!(@argv)
      reference, row_id = require_arguments!(parser, 2)
      engine.delete(reference, row_id, provenance(options))
    end

    def query_command
      options = { limit: 100, offset: 0 }
      parser = OptionParser.new do |item|
        item.banner = "Usage: kg dataset query DATASET [options]"
        item.on("--where EXPR", "Validated AND-only filter") { |value| options[:where] = value }
        item.on("--order SPEC", "column:asc,column:desc") { |value| options[:order] = value }
        item.on("--columns LIST", "Comma-separated columns") { |value| options[:columns] = value }
        item.on("--limit N", Integer, "Maximum rows") { |value| options[:limit] = value }
        item.on("--offset N", Integer, "Rows to skip") { |value| options[:offset] = value }
        json_option(item)
      end
      parser.parse!(@argv)
      reference = require_arguments!(parser, 1).first
      {
        "dataset" => reference,
        "rows" => engine.query(reference, where: options[:where], order: options[:order],
                               columns: options[:columns], limit: options[:limit], offset: options[:offset])
      }
    end

    def export_command
      options = { format: "json", limit: 10_000, force: false }
      parser = OptionParser.new do |item|
        item.banner = "Usage: kg dataset export DATASET [options]"
        item.on("--format FORMAT", "csv, json, or xlsx") { |value| options[:format] = value }
        item.on("--file PATH", "Write export to a file") { |value| options[:file] = value }
        item.on("--force", "Replace an existing export file") { options[:force] = true }
        item.on("--where EXPR", "Validated filter") { |value| options[:where] = value }
        item.on("--order SPEC", "Sort order") { |value| options[:order] = value }
        item.on("--limit N", Integer, "Maximum rows") { |value| options[:limit] = value }
        json_option(item)
      end
      parser.parse!(@argv)
      reference = require_arguments!(parser, 1).first
      result = transfer.export(
        reference, format: options[:format], path: options[:file], force: options[:force],
        where: options[:where], order: options[:order], limit: options[:limit]
      )
      if !@json && result["content"]
        @out.write(result.delete("content"))
        return nil
      end
      result
    end

    def import_command
      options = provenance_options("Usage: kg dataset import DATASET --file PATH [options]")
      parser = options.delete(:parser)
      parser.on("--file PATH", "CSV, JSON, or XLSX file") { |value| options[:file] = value }
      parser.on("--format FORMAT", "Override detected format") { |value| options[:format] = value }
      parser.parse!(@argv)
      reference = require_arguments!(parser, 1).first
      raise OptionParser::MissingArgument, "--file is required" unless options[:file]

      transfer.import(reference, path: options[:file], format: options[:format], provenance: provenance(options))
    end

    def stats_command
      parser = OptionParser.new { |item| item.banner = "Usage: kg dataset stats DATASET [--json]"; json_option(item) }
      parser.parse!(@argv)
      engine.stats(require_arguments!(parser, 1).first)
    end

    def explain_command
      options = {}
      parser = OptionParser.new do |item|
        item.banner = "Usage: kg dataset explain DATASET [ROW_ID] [options]"
        item.on("--where EXPR", "Validated filter") { |value| options[:where] = value }
        json_option(item)
      end
      parser.parse!(@argv)
      raise OptionParser::MissingArgument, "dataset is required" if @argv.empty?
      raise OptionParser::InvalidArgument, parser.banner if @argv.length > 2

      engine.explain(@argv[0], row_id: @argv[1], where: options[:where])
    end

    def migrate_command
      options = {}
      parser = OptionParser.new do |item|
        item.banner = "Usage: kg dataset migrate DATASET --schema JSON_OR_FILE [--json]"
        item.on("--schema JSON_OR_FILE", "Additive replacement schema") { |value| options[:schema] = value }
        json_option(item)
      end
      parser.parse!(@argv)
      reference = require_arguments!(parser, 1).first
      raise OptionParser::MissingArgument, "--schema is required" unless options[:schema]

      engine.migrate(reference, load_json_or_file(options[:schema]))
    end

    def provenance_options(banner)
      options = {}
      parser = OptionParser.new do |item|
        item.banner = banner
        item.on("--source SOURCE", "Provenance source") { |value| options[:source] = value }
        item.on("--observation-id ID", "Observation reference") { |value| options[:observation_id] = value }
        item.on("--proposal-id ID", "Proposal reference") { |value| options[:proposal_id] = value }
        item.on("--approval-id ID", "Approval reference") { |value| options[:approval_id] = value }
        item.on("--created-by ID", "Actor responsible for the row") { |value| options[:created_by] = value }
        json_option(item)
      end
      options[:parser] = parser
      options
    end

    def provenance(options)
      %i[source observation_id proposal_id approval_id created_by].each_with_object({}) do |key, result|
        result[key] = options[key] if options[key]
      end
    end

    def json_option(parser)
      parser.on("--json", "Emit stable machine-readable JSON") { @json = true }
      parser.on("-h", "--help", "Show command help") { raise OptionParser::InvalidArgument, parser.to_s }
    end

    def require_arguments!(parser, count)
      raise OptionParser::InvalidArgument, parser.banner unless @argv.length == count

      @argv.dup
    end

    def key_values(items)
      items.each_with_object({}) do |item, result|
        key, value = item.split("=", 2)
        raise OptionParser::InvalidArgument, "row values must use COLUMN=VALUE" if value.nil? || key.to_s.empty?

        result[key] = value
      end
    end

    def load_json_or_file(value)
      candidate = Pathname.new(value).expand_path
      source = candidate.file? ? candidate.read : value
      JSON.parse(source)
    rescue Errno::EACCES, Errno::EISDIR
      raise ArgumentError, "JSON file could not be read"
    end

    def engine
      @engine ||= Engine.new(
        vault_root: @vault_root, run_id: @run_id, actor_id: @actor_id, event_bus: @event_bus
      )
    end

    def transfer
      @transfer ||= ImportExport.new(engine: engine)
    end

    def emit(value)
      return if value.nil?

      if @json
        @out.puts(JSON.pretty_generate("status" => "ok", "result" => value))
      else
        @out.puts(JSON.pretty_generate(value))
      end
    end

    def help
      @out.puts("Usage: kg dataset COMMAND [options]")
      @out.puts("Commands: #{COMMANDS.join(', ')}")
      0
    end
  end
end
