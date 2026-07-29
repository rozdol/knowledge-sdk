# frozen_string_literal: true

require "json"
require "optparse"

module KnowledgeIntelligence
  class CLI
    ANALYZER_ALIASES = {
      "relationships" => "relationship", "relationship" => "relationship",
      "opportunities" => "opportunity", "opportunity" => "opportunity",
      "gaps" => "knowledge_gap", "knowledge-gaps" => "knowledge_gap",
      "followups" => "followup", "follow-up" => "followup",
      "activity" => "activity", "timeline" => "timeline", "network" => "network",
      "memory" => "memory", "projects" => "project", "project" => "project",
      "anomalies" => "anomaly", "anomaly" => "anomaly", "consistency" => "consistency",
      "recommendations" => "recommendation", "recommendation" => "recommendation"
    }.freeze

    def initialize(argv:, out:, err:, vault_root:)
      @argv = argv.dup
      @out = out
      @err = err
      @vault_root = vault_root.to_s
      @options = { as_of: Date.today, profile: false, format: "json", persist: false }
    end

    def run
      command = @argv.shift
      return help unless command
      parse_options!
      case command
      when *ANALYZER_ALIASES.keys then analyzer_command(ANALYZER_ALIASES.fetch(command))
      when "all" then emit(run_engine)
      when "digest" then digest_command
      when "report" then report_command
      when "query" then query_command
      when "features" then features_command
      when "explain" then explain_command
      when "proposal", "propose" then proposal_command
      when "help", "--help", "-h" then help
      else raise Error, "unknown intelligence command #{command.inspect}"
      end
      0
    rescue OptionParser::ParseError, ArgumentError, InvalidQuery, Error => error
      @err.puts(JSON.generate(error: error.message, error_class: error.class.name))
      2
    end

    private

    def parse_options!
      OptionParser.new do |options|
        options.on("--as-of DATE", "Deterministic analysis date") { |value| @options[:as_of] = Date.iso8601(value) }
        options.on("--profile", "Include non-deterministic runtime measurements") { @options[:profile] = true }
        options.on("--format FORMAT", "json or markdown") { |value| @options[:format] = value }
        options.on("--person QUERY", "Person ID, name, or alias") { |value| @options[:person] = value }
        options.on("--period PERIOD", "daily, weekly, or monthly") { |value| @options[:period] = value }
        options.on("--rules PATH", "Recommendation rule YAML") { |value| @options[:rules] = value }
        options.on("--persist", "Persist proposal JSON for the existing approval system") { @options[:persist] = true }
      end.parse!(@argv)
      raise ArgumentError, "format must be json or markdown" unless %w[json markdown].include?(@options[:format])
    end

    def analyzer_command(name)
      analyzer_config = {}
      if name == "memory" && @options[:person]
        analyzer_config[:memory_person_ids] = resolve_records(@options[:person], type: "person").map(&:id)
      end
      emit(run_engine(names: [name], analyzer_config: analyzer_config))
    end

    def digest_command
      period = @options[:period] || "weekly"
      days = { "daily" => 1, "weekly" => 7, "monthly" => 30 }[period]
      raise ArgumentError, "period must be daily, weekly, or monthly" unless days

      run = run_engine
      emit(DigestBuilder.new(snapshot: snapshot, as_of: @options[:as_of]).build(run, days: days))
    end

    def report_command
      name = @argv.shift || raise(ArgumentError, "report name is required")
      emit(ReportEngine.new(snapshot: snapshot, as_of: @options[:as_of]).build(name, run_engine))
    end

    def query_command
      text = @argv.join(" ").strip
      raise ArgumentError, "query text is required" if text.empty?

      features = FeatureEngine.new(
        snapshot: snapshot, registry: DefaultFeatures.registry, as_of: @options[:as_of]
      )
      emit(QueryEngine.new(snapshot: snapshot, feature_engine: features, as_of: @options[:as_of]).query(text))
    end

    def features_command
      registry = DefaultFeatures.registry
      if @options[:person]
        record = resolve_records(@options[:person], type: "person").first
        engine = FeatureEngine.new(snapshot: snapshot, registry: registry, as_of: @options[:as_of])
        values = registry.names.reject { |name| registry.fetch(name).scope == "pair" }.map do |name|
          engine.fetch(name, subject_id: record.id).to_h
        end
        emit_hash(entity_id: record.id, features: values, metrics: engine.metrics)
      else
        emit_hash(features: registry.names.map do |name|
          definition = registry.fetch(name)
          { name: name, version: definition.version, scope: definition.scope,
            dependencies: definition.dependencies }
        end)
      end
    end

    def explain_command
      finding_id = @argv.shift || raise(ArgumentError, "finding ID is required")
      finding = run_engine.findings.find { |item| item.finding_id == finding_id }
      raise Error, "finding not found: #{finding_id}" unless finding

      emit_hash(finding: finding.to_h, why: finding.explanation,
                evidence: finding.evidence.map(&:to_h), graph_path: finding.graph_path)
    end

    def proposal_command
      finding_id = @argv.shift
      payload = ProposalAdapter.new.build(run_engine(names: ["recommendation"]), finding_ids: finding_id && [finding_id])
      path = ProposalAdapter.new.persist(payload, vault_root: @vault_root) if @options[:persist]
      emit_hash(proposal: payload, persisted_path: path && path.to_s)
    end

    def run_engine(names: nil, analyzer_config: {})
      AnalysisEngine.new(
        snapshot: snapshot,
        analyzers: DefaultAnalyzers.build(rule_path: @options[:rules] || DefaultAnalyzers.default_rule_path),
        as_of: @options[:as_of], analyzer_config: analyzer_config,
        profile: @options[:profile]
      ).run(names: names)
    end

    def snapshot
      @snapshot ||= GraphSnapshot.load(vault_root: @vault_root)
    end

    def resolve_records(query, type: nil)
      direct = snapshot.record(query)
      return [direct] if direct && (!type || direct.type == type)

      normalized = query.to_s.downcase
      matches = snapshot.records(type: type).select do |record|
        ([record.name] + Array(record["aliases"])).compact.any? { |name| name.to_s.downcase.include?(normalized) }
      end
      raise Error, "no matching #{type || 'entity'}: #{query}" if matches.empty?
      raise Error, "ambiguous #{type || 'entity'}: #{matches.map(&:name).join(', ')}" if matches.length > 1

      matches
    end

    def emit(object)
      emit_hash(object.respond_to?(:to_h) ? object.to_h : object)
    end

    def emit_hash(value)
      if @options[:format] == "json"
        @out.puts(JSON.pretty_generate(Immutable.canonical(value)))
      else
        @out.puts(markdown(value))
      end
    end

    def markdown(value)
      hash = Immutable.canonical(value)
      title = hash["name"] || hash["analyzer"] || hash["kind"] || "Knowledge Intelligence"
      lines = ["# #{title}", ""]
      if hash["summary"]
        lines << hash["summary"] << ""
      elsif hash["results"]
        hash["results"].each do |result|
          lines << "## #{result['analyzer']}" << ""
          result["findings"].each do |finding|
            lines << "- **#{finding['title']}** — #{finding['explanation']} (confidence #{finding['confidence']})"
          end
          lines << ""
        end
      else
        lines << "```json" << JSON.pretty_generate(hash) << "```"
      end
      lines.join("\n")
    end

    def help
      @out.puts("Usage: kg intelligence COMMAND [options]")
      @out.puts("Commands: relationships, opportunities, gaps, followups, activity, timeline, network,")
      @out.puts("          projects, memory, recommendations, anomalies, consistency, all, digest,")
      @out.puts("          report, query, features, explain, proposal")
      0
    end
  end
end
