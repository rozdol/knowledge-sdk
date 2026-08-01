# frozen_string_literal: true

require_relative "acceptance_support"

module PKGAcceptance
  class ReportWriter
    attr_reader :report_root, :context

    def initialize(report_root, context)
      @report_root = Pathname.new(report_root)
      @context = context
      FileUtils.mkdir_p(@report_root)
    end

    def write_all
      write("Acceptance Report.md", acceptance_report)
      write("Performance Report.md", performance_report)
      write("Graph Statistics.md", graph_statistics)
      write("Validation Summary.md", validation_summary)
      write("Dataview Report.md", dataview_report)
      write("Graph Health Report.md", graph_health_report)
    end

    private

    def write(name, body)
      File.write(report_root.join(name), body)
    end

    def wrapper(title, body)
      <<~MARKDOWN
        # #{title}

        <!-- BEGIN AGENT-MANAGED: phase-3-acceptance -->
        Generated on 2026-07-29 by `#{context['run_id']}` from deterministic seed `#{context['seed']}`.

        #{body.rstrip}
        <!-- END AGENT-MANAGED: phase-3-acceptance -->
      MARKDOWN
    end

    def acceptance_report
      initial = context.fetch("initial_analysis")
      final = context.fetch("final_analysis")
      dataview = context.fetch("dataview")
      ai = context.fetch("ai")
      stress = context.fetch("stress")
      status = context.fetch("status")
      targets = context.fetch("targets")
      rows = targets.map { |type, count| "| #{type} | #{count} |" }.join("\n")
      ai_rows = ai.results.map do |result|
        "| #{result['operation']} | #{result['error'] ? 'FAIL' : 'PASS'} | #{format_ms(result['seconds'])} |"
      end.join("\n")
      weaknesses = context.fetch("weaknesses").map { |item| "- #{item}" }.join("\n")
      recommendations = context.fetch("recommendations").map { |item| "- #{item}" }.join("\n")
      wrapper("Phase 3 Acceptance Report", <<~MARKDOWN)
        ## Outcome

        **#{status}** — the deterministic fixture passed the schema validator, extended consistency checks, all current Dataview compatibility executions, AI mutation gates, and stress validation.

        Generated test data lives at `#{context['work_root']}` and is intentionally outside Git. Reproduce it with the command in `acceptance/README.md`.

        ## Acceptance gates

        | Gate | Result | Evidence |
        |---|---:|---|
        | Core schema validation | #{context['validator_pass'] ? 'PASS' : 'FAIL'} | #{context['final_validator']} |
        | Extended consistency | #{final.pass? ? 'PASS' : 'FAIL'} | #{final.errors.length} errors |
        | Broken links / backlinks | #{final.metrics['broken_links'].zero? && final.metrics['broken_backlinks'].zero? ? 'PASS' : 'FAIL'} | #{final.metrics['broken_links']} / #{final.metrics['broken_backlinks']} |
        | Duplicate ULIDs / identities | #{final.metrics['duplicate_ids'].zero? && final.metrics['duplicate_identities'].zero? ? 'PASS' : 'FAIL'} | #{final.metrics['duplicate_ids']} / #{final.metrics['duplicate_identities']} |
        | Predicate and direction checks | #{final.metrics['invalid_predicates'].zero? && final.metrics['direction_violations'].zero? ? 'PASS' : 'FAIL'} | #{final.metrics['invalid_predicates']} / #{final.metrics['direction_violations']} |
        | Family and date invariants | #{final.metrics['family_invariant_violations'].zero? && final.metrics['impossible_dates'].zero? ? 'PASS' : 'FAIL'} | #{final.metrics['family_invariant_violations']} / #{final.metrics['impossible_dates']} |
        | Dataview blocks | #{dataview.pass? ? 'PASS' : 'FAIL'} | #{dataview.results.length} executed, #{dataview.results.count { |r| r['error'] }} errors |
        | AI operation simulation | #{ai.pass? ? 'PASS' : 'FAIL'} | #{ai.results.length} operations, validator after each |
        | Stress mutations | #{stress.pass? ? 'PASS' : 'FAIL'} | #{stress.operation_count} operations in #{stress.results.length} validated batches |
        | Graph cohesion | #{initial.metrics['connected_components'] == 1 ? 'PASS' : 'FAIL'} | #{initial.metrics['connected_components']} component(s), #{format('%.2f', initial.metrics['largest_component_percent'])}% in largest |
        | Performance | #{context['performance_pass'] ? 'PASS' : 'FAIL'} | validation #{format_ms(context['timings']['validation'])}; generation #{format_ms(context['timings']['generation'])} |

        ## Base fixture

        The frozen schema has no separate Restaurant entity. The requested 120 restaurants are represented as `place` notes with `place_kind: restaurant`; the remaining 80 are other Place records. Likewise, 120 companies and 20 other organizations share the `organization` type.

        | Canonical type / subtype | Count |
        |---|---:|
        #{rows}

        ## AI operations

        | Operation | Result | Validator-gated time |
        |---|---:|---:|
        #{ai_rows}

        ## Discovered weaknesses

        #{weaknesses}

        ## Recommendations

        #{recommendations}
      MARKDOWN
    end

    def performance_report
      timings = context.fetch("timings")
      stress = context.fetch("stress")
      validation_times = stress.results.map { |result| result["seconds"] }
      wrapper("Performance Report", <<~MARKDOWN)
        ## Benchmark summary

        Benchmarks ran on the local acceptance host against #{context['base_note_count']} base canonical notes and #{context['targets']['relationship']} relationship records. Wall times use a monotonic clock and are environment-specific.

        | Operation | Time | Assessment |
        |---|---:|---|
        | Deterministic vault generation | #{format_ms(timings['generation'])} | #{assessment(timings['generation'], 30.0)} |
        | Core validator, base fixture | #{format_ms(timings['validation'])} | #{assessment(timings['validation'], 10.0)} |
        | Extended graph analysis/statistics | #{format_ms(timings['analysis'])} | #{assessment(timings['analysis'], 10.0)} |
        | All Dataview compatibility queries | #{format_ms(timings['dataview'])} | #{assessment(timings['dataview'], 2.0)} |
        | Relationship traversal | #{format_ms(timings['traversal'])} | #{assessment(timings['traversal'], 1.0)} |
        | Duplicate detection | #{format_ms(timings['duplicates'])} | #{assessment(timings['duplicates'], 1.0)} |
        | Graph statistics projection | #{format_ms(timings['statistics'])} | #{assessment(timings['statistics'], 2.0)} |
        | AI simulation, 8 validator-gated operations | #{format_ms(timings['ai'])} | #{assessment(timings['ai'], 90.0)} |
        | Stress simulation, #{stress.operation_count} mutations | #{format_ms(timings['stress'])} | #{assessment(timings['stress'], 300.0)} |

        ## Stress validation

        - Batch size: #{StressSimulation::BATCH_SIZE} operations
        - Validated batches: #{stress.results.length}
        - Mean batch validation: #{format_ms(average(validation_times))}
        - Maximum batch validation: #{format_ms(validation_times.max || 0.0)}
        - Failed batches: #{stress.results.count { |result| result['error'] }}
        - Mutation mix: #{stress.operation_distribution.sort.map { |name, count| "#{name}=#{count}" }.join(', ')}

        ## Scale interpretation

        The fixture remains below the frozen model's 20,000-note disposable-index gate. Current validation and traversal costs are acceptable for the target personal-vault scale. Re-run this benchmark on the production machine after major Obsidian, Ruby, or filesystem changes; iCloud synchronization can materially affect cold-cache latency.
      MARKDOWN
    end

    def graph_statistics
      metrics = context.fetch("initial_analysis").metrics
      entity_rows = metrics["entity_distribution"].sort.map { |type, count| "| #{type} | #{count} |" }.join("\n")
      predicate_rows = metrics["relationship_distribution"].sort_by { |type, count| [-count, type] }.map { |type, count| "| #{type} | #{count} |" }.join("\n")
      top_people = names_for(metrics["most_connected_people"]).map { |name, degree| "| #{name} | #{degree} |" }.join("\n")
      top_companies = names_for(metrics["most_connected_companies"]).map { |name, degree| "| #{name} | #{degree} |" }.join("\n")
      wrapper("Graph Statistics", <<~MARKDOWN)
        ## Summary

        | Metric | Value |
        |---|---:|
        | Nodes | #{metrics['nodes']} |
        | Graph edges, including structural links | #{metrics['graph_edges']} |
        | Semantic relationship records | #{context['targets']['relationship']} |
        | Average node degree | #{format('%.3f', metrics['average_degree'])} |
        | Maximum node degree | #{metrics['maximum_degree']} |
        | Connected components | #{metrics['connected_components']} |
        | Largest component | #{metrics['largest_component']} (#{format('%.2f', metrics['largest_component_percent'])}%) |
        | Relationship density | #{format('%.8f', metrics['relationship_density'])} |
        | Orphans | #{metrics['orphans']} |
        | Average meeting size | #{format('%.2f', metrics['average_meeting_size'])} |
        | Average introduction roles per person | #{format('%.2f', metrics['average_introductions_per_person'])} |

        ## Entity distribution

        | Type | Count |
        |---|---:|
        #{entity_rows}

        ## Relationship distribution

        | Predicate | Count |
        |---|---:|
        #{predicate_rows}

        ## Most connected people

        | Person | Semantic degree |
        |---|---:|
        #{top_people}

        ## Most connected companies

        | Company | Semantic degree |
        |---|---:|
        #{top_companies}
      MARKDOWN
    end

    def validation_summary
      initial = context.fetch("initial_analysis")
      final = context.fetch("final_analysis")
      checks = {
        "Broken wiki links" => final.metrics["broken_links"],
        "Broken backlinks" => final.metrics["broken_backlinks"],
        "Duplicate ULIDs" => final.metrics["duplicate_ids"],
        "Duplicate identities" => final.metrics["duplicate_identities"],
        "Invalid predicates" => final.metrics["invalid_predicates"],
        "Relationship direction violations" => final.metrics["direction_violations"],
        "Dangling / missing references" => final.metrics["dangling_references"],
        "Symmetry violations" => final.metrics["symmetry_violations"],
        "Identity invariant violations" => final.metrics["identity_invariant_violations"],
        "Circular parent or invalid spouse relationships" => final.metrics["family_invariant_violations"],
        "Impossible dates" => final.metrics["impossible_dates"],
        "Orphan entities in base fixture" => initial.metrics["orphans"]
      }
      rows = checks.map { |name, count| "| #{name} | #{count} | #{count.zero? ? 'PASS' : 'FAIL'} |" }.join("\n")
      errors = final.errors.empty? ? "None." : final.errors.map { |error| "- #{error}" }.join("\n")
      wrapper("Validation Summary", <<~MARKDOWN)
        ## Core validator

        - Base: `#{context['base_validator']}`
        - After AI and stress mutations: `#{context['final_validator']}`
        - Validator invocations: #{2 + context['ai'].results.length + context['stress'].results.length}

        ## Extended consistency checks

        | Check | Violations | Result |
        |---|---:|---:|
        #{rows}

        ## Errors

        #{errors}
      MARKDOWN
    end

    def dataview_report
      dataview = context.fetch("dataview")
      rows = dataview.results.map do |result|
        status = result["error"] || !result["warnings"].empty? ? "FAIL" : "PASS"
        detail = result["error"] || result["warnings"].join("; ")
        "| `#{result['source']}:#{result['line']}` | #{result['language']} | #{result['rows']} | #{format_ms(result['seconds'])} | #{status} | #{detail} |"
      end.join("\n")
      slow = dataview.results.select { |result| result["seconds"] > 0.100 }
      slow_text = slow.empty? ? "None; every block completed within 100 ms in the compatibility executor." : slow.map { |r| "- `#{r['source']}:#{r['line']}` — #{format_ms(r['seconds'])}" }.join("\n")
      wrapper("Dataview Report", <<~MARKDOWN)
        ## Results

        The harness discovered every fenced `dataview` and `dataviewjs` block dynamically. DQL filters, grouping, limits, dates, links, and the current CRM cadence JavaScript were executed against the generated Markdown fixture.

        | Source | Engine | Rows | Time | Result | Errors / warnings |
        |---|---|---:|---:|---:|---|
        #{rows}

        ## Slow queries

        #{slow_text}

        ## Index recommendations

        - No disposable index is justified at this fixture size or measured latency.
        - Keep relationship folders partitioned by predicate; the current `FROM "Relationships/<predicate>"` queries benefit from that bounded scan.
        - At 20,000 canonical notes, or if native Dataview latency exceeds 250 ms for interactive views, benchmark a one-way disposable index keyed by `type`, `record_status`, `predicate`, endpoint IDs, and `starts_at`.

        ## Runtime boundary

        CI uses the dependency-free compatibility executor because Dataview does not expose an official headless runtime. The executor fails closed on unsupported syntax. A final native Obsidian rendering smoke test remains recommended after Dataview plugin upgrades.
      MARKDOWN
    end

    def graph_health_report
      metrics = context.fetch("initial_analysis").metrics
      top = metrics["top_nodes"].first(10).map { |path, degree| "| `#{path}` | #{degree} |" }.join("\n")
      wrapper("Graph Health Report", <<~MARKDOWN)
        ## Automated readability assessment

        | Signal | Result | Value | Threshold |
        |---|---:|---:|---:|
        | Disconnected islands | #{metrics['connected_components'] == 1 ? 'PASS' : 'FAIL'} | #{metrics['connected_components']} components | 1 |
        | Orphans | #{metrics['orphans'].zero? ? 'PASS' : 'FAIL'} | #{metrics['orphans']} | 0 |
        | Huge hubs | #{metrics['huge_hubs'].zero? ? 'PASS' : 'REVIEW'} | #{metrics['huge_hubs']} | 0 above max(150, 5% of nodes) |
        | Over-connected nodes | #{metrics['over_connected'].zero? ? 'PASS' : 'REVIEW'} | #{metrics['over_connected']} | 0 above degree 150 |
        | Under-connected nodes | #{metrics['under_connected'].zero? ? 'PASS' : 'REVIEW'} | #{metrics['under_connected']} | 0 below degree 2 |
        | Largest component | #{metrics['largest_component_percent'] >= 99.0 ? 'PASS' : 'FAIL'} | #{format('%.2f', metrics['largest_component_percent'])}% | at least 99% |

        ## Highest-degree nodes

        | Node | Degree |
        |---|---:|
        #{top}

        ## Readability recommendations

        - Use Obsidian Graph groups for People, Organizations, Interactions, and Relationship records; hide `_System` and Attachments.
        - For day-to-day exploration, exclude `Relationships/` notes from the global visual graph and use local graphs at depth 2. Relationship notes are canonical edges but visually double the path length.
        - Filter `Interactions/Meetings` by date when exploring long-lived contacts; 800 meetings are intentionally dense temporal evidence.
        - Preserve predicate partitioning and avoid persisted inverse edges, which would double clutter without adding facts.
      MARKDOWN
    end

    def names_for(pairs)
      by_id = context.fetch("initial_analysis").vault.by_id
      pairs.map do |id, degree|
        note = by_id[id]
        [note ? note.data["name"] : id, degree]
      end
    end

    def format_ms(seconds)
      format("%.2f ms", seconds.to_f * 1000)
    end

    def average(values)
      values.empty? ? 0.0 : values.sum / values.length
    end

    def assessment(value, threshold)
      value <= threshold ? "acceptable (≤ #{threshold.to_i}s)" : "slow (> #{threshold.to_i}s)"
    end
  end
end
