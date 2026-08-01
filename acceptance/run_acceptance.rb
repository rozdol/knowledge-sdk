#!/usr/bin/env ruby
# frozen_string_literal: true

require "optparse"
require_relative "lib/acceptance_support"
require_relative "lib/generator"
require_relative "lib/dataview_runner"
require_relative "lib/simulations"
require_relative "lib/report_writer"

source_root = Pathname.new(File.expand_path("..", __dir__))
options = {
  seed: "pkg-phase3-v1",
  run_id: "run_#{PKGAcceptance.deterministic_ulid('pkg-phase3-v1', 'acceptance-run', 0)}",
  stress_operations: 2_000,
  work_root: nil,
  report_root: source_root.join("acceptance/Reports")
}
OptionParser.new do |parser|
  parser.banner = "Usage: ruby 'acceptance/run_acceptance.rb' [options]"
  parser.on("--seed SEED", "Deterministic fixture seed") { |value| options[:seed] = value }
  parser.on("--run-id RUN_ID", "Agent run_<ULID> written to generated records") { |value| options[:run_id] = value }
  parser.on("--stress-operations N", Integer, "Number of deterministic stress mutations") { |value| options[:stress_operations] = value }
  parser.on("--work-root PATH", "Generated vault location under /private/tmp/pkg-acceptance-*") { |value| options[:work_root] = Pathname.new(value) }
  parser.on("--report-root PATH", "Markdown report output") { |value| options[:report_root] = Pathname.new(value) }
end.parse!

unless options[:run_id].match?(/\Arun_[0-9A-HJKMNP-TV-Z]{26}\z/)
  abort "--run-id must have the form run_<26-character-ULID>"
end
work_slug = options[:seed].gsub(/[^a-zA-Z0-9.-]+/, "-")
options[:work_root] ||= Pathname.new("/private/tmp/pkg-acceptance-#{work_slug}")

timings = {}
generator = PKGAcceptance::Generator.new(
  source_root: source_root, root: options[:work_root], seed: options[:seed], run_id: options[:run_id]
)
_, timings["generation"] = PKGAcceptance.benchmark { generator.generate! }

base_vault = PKGAcceptance::Vault.new(options[:work_root])
base_validation, timings["validation"] = PKGAcceptance.benchmark { base_vault.validate! }
registry = PKGAcceptance.load_relationship_registry(options[:work_root])
initial_analysis, timings["analysis"] = PKGAcceptance.benchmark do
  PKGAcceptance::Analyzer.new(base_vault, registry).run
end

dataview, timings["dataview"] = PKGAcceptance.benchmark do
  PKGAcceptance::DataviewRunner.new(base_vault, source_root.join("plugins/personal-crm/views")).run!
end

_, timings["traversal"] = PKGAcceptance.benchmark do
  base_vault.notes_of("relationship").each_with_object(Hash.new(0)) do |note, degree|
    degree[note.data["subject_id"]] += 1
    degree[note.data["object_id"]] += 1
  end
end
_, timings["duplicates"] = PKGAcceptance.benchmark do
  tokens = Hash.new(0)
  base_vault.notes.each do |note|
    Array(note.data["emails"]).each { |email| tokens["email:#{email.downcase}"] += 1 }
    Array(note.data["external_ids"]).each { |id| tokens["external:#{id.downcase}"] += 1 }
    tokens["domain:#{note.data['primary_domain'].downcase}"] += 1 if note.data["primary_domain"]
  end
  tokens.select { |_token, count| count > 1 }
end
_, timings["statistics"] = PKGAcceptance.benchmark do
  initial_analysis.metrics["entity_distribution"].sort
  initial_analysis.metrics["relationship_distribution"].sort_by { |predicate, count| [-count, predicate] }
  initial_analysis.metrics["component_sizes"].sort.reverse
end

ai, timings["ai"] = PKGAcceptance.benchmark do
  PKGAcceptance::AISimulation.new(root: options[:work_root], seed: options[:seed], run_id: options[:run_id]).run!
end
stress, timings["stress"] = PKGAcceptance.benchmark do
  PKGAcceptance::StressSimulation.new(
    root: options[:work_root], seed: options[:seed], run_id: options[:run_id], operation_count: options[:stress_operations]
  ).run!
end

final_vault = PKGAcceptance::Vault.new(options[:work_root])
final_validation = final_vault.validate!
final_analysis = PKGAcceptance::Analyzer.new(final_vault, registry).run

targets = PKGAcceptance::Generator::ENTITY_TARGETS.dup
targets = {
  "people" => targets.delete("person"), "companies" => 120, "other organizations" => 20,
  "cities" => targets.delete("city"), "countries" => targets.delete("country"),
  "projects" => targets.delete("project"), "meetings" => targets.delete("interaction"),
  "interests" => targets.delete("interest"), "technologies" => targets.delete("technology"),
  "restaurants" => 120, "other places" => 80, "events" => targets.delete("event"),
  "books" => targets.delete("book"), "introductions" => targets.delete("introduction"),
  "promises" => targets.delete("commitment"), "follow-ups" => targets.delete("follow-up"),
  "languages" => targets.delete("language"), "professions" => targets.delete("profession"),
  "industries" => targets.delete("industry"), "relationship" => targets.delete("relationship")
}

performance_pass = timings["generation"] <= 30.0 && timings["validation"] <= 10.0 &&
  timings["dataview"] <= 2.0 && timings["analysis"] <= 10.0
validator_pass = base_validation && final_validation
status_pass = validator_pass && initial_analysis.pass? && final_analysis.pass? && dataview.pass? &&
  ai.pass? && stress.pass? && performance_pass && initial_analysis.metrics["connected_components"] == 1 &&
  initial_analysis.metrics["orphans"].zero?

context = {
  "run_id" => options[:run_id], "seed" => options[:seed], "work_root" => options[:work_root],
  "status" => status_pass ? "PASS" : "FAIL", "validator_pass" => !!validator_pass,
  "performance_pass" => performance_pass, "base_validator" => base_validation["stdout"],
  "final_validator" => final_validation["stdout"], "base_note_count" => base_vault.notes.length,
  "initial_analysis" => initial_analysis, "final_analysis" => final_analysis,
  "dataview" => dataview, "ai" => ai, "stress" => stress, "timings" => timings, "targets" => targets,
  "weaknesses" => [
    "Dataview has no official headless execution API; automation therefore uses a fail-closed compatibility executor and cannot prove Electron rendering behavior.",
    "Relationship records are excellent canonical facts but create visual two-hop clutter when displayed directly in Obsidian's global graph.",
    "Cold-cache performance on iCloud-backed storage can differ from this `/private/tmp` benchmark and should be sampled on the production vault."
  ],
  "recommendations" => [
    "Run a native Obsidian smoke test after Dataview plugin upgrades; retain this compatibility suite as the deterministic CI gate.",
    "Hide Relationship and old Meeting notes in the global graph, using local graphs and predicate views for investigation.",
    "Keep the 20,000-note scale gate; add only a disposable one-way index if native query latency exceeds 250 ms.",
    "Run this acceptance suite before schema migrations and compare benchmark deltas against the committed Phase 3 baseline."
  ]
}
PKGAcceptance::ReportWriter.new(options[:report_root], context).write_all

puts "#{context['status']}: #{base_vault.notes.length} base notes, #{dataview.results.length} Dataview blocks, " \
     "#{stress.operation_count} stress operations"
puts "Generated vault: #{options[:work_root]}"
puts "Reports: #{options[:report_root]}"
unless status_pass
  warn "Initial analysis errors: #{initial_analysis.errors.join('; ')}" unless initial_analysis.pass?
  warn "Final analysis errors: #{final_analysis.errors.join('; ')}" unless final_analysis.pass?
  dataview.results.each { |result| warn "Dataview #{result['source']}:#{result['line']}: #{result['error']}" if result["error"] }
  exit 1
end
