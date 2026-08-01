# frozen_string_literal: true

require "date"
require "digest"
require "fileutils"
require "open3"
require "pathname"
require "time"
require "yaml"

module PKGAcceptance
  SDK_ROOT = Pathname.new(File.expand_path("../..", __dir__)).freeze
  SCHEMA_VERSION = 1
  FIXED_NOW = Time.new(2026, 7, 29, 12, 0, 0, "+03:00")
  ULID_ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
  WIKILINK = /\A\[\[([^\]|#]+)(?:#[^\]|]+)?(?:\|[^\]]+)?\]\]\z/.freeze
  COMMON_TYPES = %w[
    person organization interaction introduction place project book interest technology country city event
    commitment follow-up relationship language profession industry
  ].freeze

  module_function

  def benchmark
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = yield
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    [result, elapsed]
  end

  def deterministic_ulid(seed, namespace, index, time = FIXED_NOW)
    milliseconds = (time.to_f * 1000).to_i + index
    time_part = 10.times.map do
      character = ULID_ALPHABET[milliseconds % 32]
      milliseconds /= 32
      character
    end.reverse.join
    bits = Digest::SHA256.digest("#{seed}:#{namespace}:#{index}").unpack1("B*")[0, 80]
    random_part = bits.scan(/.{5}/).map { |chunk| ULID_ALPHABET[chunk.to_i(2)] }.join
    time_part + random_part
  end

  def scalar_time(value)
    return value if value.is_a?(Time) || value.is_a?(Date) || value.is_a?(DateTime)
    return nil unless value.is_a?(String)

    Time.parse(value)
  rescue ArgumentError
    begin
      Date.parse(value)
    rescue ArgumentError
      nil
    end
  end

  def link_target(value)
    return nil unless value.is_a?(String)

    match = value.match(WIKILINK)
    match && match[1].sub(/\.md\z/, "")
  end

  def link(path, label = nil)
    label ? "[[#{path}|#{label}]]" : "[[#{path}]]"
  end

  def safe_filename(name)
    name.gsub(/[\\\/:*?"<>|#\[\]]/, "-").gsub(/\s+/, " ").strip
  end

  def canonical_path(root, relative)
    Pathname.new(root).join(relative.sub(/\.md\z/, "") + ".md")
  end

  class NoteIO
    FRONTMATTER = /\A---\s*\r?\n(.*?)\r?\n---\s*(?:\r?\n|\z)/m.freeze

    def self.read(path)
      content = File.read(path)
      match = content.match(FRONTMATTER)
      raise "#{path}: missing or unclosed frontmatter" unless match

      data = YAML.safe_load(match[1], permitted_classes: [Date, Time], aliases: false)
      raise "#{path}: frontmatter must be a mapping" unless data.is_a?(Hash)

      [data.transform_keys(&:to_s), content[match.end(0)..-1].to_s]
    end

    def self.write(path, data, body = "")
      FileUtils.mkdir_p(File.dirname(path))
      yaml = YAML.dump(data).sub(/\A---\s*\n/, "")
      File.write(path, "---\n#{yaml}---\n#{body}")
    end

    def self.update(path)
      data, body = read(path)
      yield data
      write(path, data, body)
    end
  end

  Note = Struct.new(:path, :relative, :data, :body) do
    def type
      data["type"]
    end

    def id
      data["id"]
    end

    def active?
      data["record_status"] == "active"
    end
  end

  class Vault
    attr_reader :root, :notes, :by_path, :by_id

    def initialize(root)
      @root = Pathname.new(root)
      reload
    end

    def reload
      @notes = []
      Dir.glob(root.join("**/*.md").to_s).sort.each do |filename|
        relative = Pathname.new(filename).relative_path_from(root).to_s
        next if relative.start_with?("_System/")

        begin
          data, body = NoteIO.read(filename)
        rescue StandardError
          next
        end
        next unless COMMON_TYPES.include?(data["type"])

        @notes << Note.new(Pathname.new(filename), relative, data, body)
      end
      @by_path = @notes.each_with_object({}) { |note, index| index[note.relative.sub(/\.md\z/, "")] = note }
      @by_id = @notes.each_with_object({}) { |note, index| index[note.id] = note if note.id }
      self
    end

    def notes_of(type)
      notes.select { |note| note.type == type }
    end

    def links(note)
      note.data.values.flat_map { |value| value.is_a?(Array) ? value : [value] }
          .map { |value| PKGAcceptance.link_target(value) }.compact
    end

    def validator_path
      SDK_ROOT.join("validators/personal_crm/validate_vault.rb")
    end

    def validate!
      stdout, stderr, status = Open3.capture3({ "VAULT_ROOT" => root.to_s }, "ruby", validator_path.to_s)
      raise "validator failed:\n#{stdout}#{stderr}" unless status.success?

      { "stdout" => stdout.strip, "stderr" => stderr.strip }
    end
  end

  class Analyzer
    attr_reader :vault, :relationship_registry, :errors, :warnings, :metrics, :adjacency

    def initialize(vault, relationship_registry)
      @vault = vault
      @relationship_registry = relationship_registry
      @errors = []
      @warnings = []
      @metrics = {}
      @adjacency = Hash.new { |hash, key| hash[key] = {} }
    end

    def run
      check_links_and_backlinks
      check_identities
      check_relationships
      check_dates
      check_family_invariants
      build_graph_metrics
      self
    end

    def pass?
      errors.empty?
    end

    private

    def check_links_and_backlinks
      outgoing = 0
      incoming = Hash.new(0)
      vault.notes.each do |note|
        vault.links(note).each do |target|
          outgoing += 1
          destination = vault.by_path[target]
          if destination
            incoming[target] += 1
            add_undirected(note.relative.sub(/\.md\z/, ""), target)
          else
            errors << "broken wiki link: #{note.relative} -> #{target}"
          end
        end
      end
      observed_backlinks = incoming.values.sum
      errors << "backlink index mismatch: #{outgoing} outgoing vs #{observed_backlinks} incoming" unless outgoing == observed_backlinks
      metrics["wiki_links"] = outgoing
      metrics["broken_links"] = errors.count { |error| error.start_with?("broken wiki link") }
      metrics["broken_backlinks"] = outgoing - observed_backlinks
    end

    def check_identities
      ids = Hash.new { |hash, key| hash[key] = [] }
      identity_tokens = Hash.new { |hash, key| hash[key] = [] }
      vault.notes.each do |note|
        ids[note.id] << note.relative
        next unless note.active?

        if note.type == "person"
          Array(note.data["emails"]).each { |email| identity_tokens["email:#{email.downcase}"] << note.relative }
          Array(note.data["phones"]).each { |phone| identity_tokens["phone:#{phone}"] << note.relative }
          Array(note.data["external_ids"]).each { |id| identity_tokens["external:#{id.downcase}"] << note.relative }
        elsif note.type == "organization"
          domain = note.data["primary_domain"]
          identity_tokens["domain:#{domain.downcase}"] << note.relative if domain
          Array(note.data["external_ids"]).each { |id| identity_tokens["external:#{id.downcase}"] << note.relative }
        end
      end
      ids.each { |id, paths| errors << "duplicate ULID/ID #{id}: #{paths.join(', ')}" if id && paths.length > 1 }
      identity_tokens.each do |token, paths|
        errors << "duplicate identity #{token}: #{paths.join(', ')}" if paths.uniq.length > 1
      end
      active_self = vault.notes_of("person").select { |note| note.active? && note.data["is_self"] == true }
      errors << "identity invariant: expected one active Self, found #{active_self.length}" unless active_self.length == 1
      metrics["duplicate_ids"] = errors.count { |error| error.start_with?("duplicate ULID/ID") }
      metrics["duplicate_identities"] = errors.count { |error| error.start_with?("duplicate identity") }
      metrics["identity_invariant_violations"] = errors.count { |error| error.start_with?("identity invariant") }
    end

    def check_relationships
      semantic = {}
      vault.notes_of("relationship").each do |note|
        data = note.data
        registry = relationship_registry[data["predicate"]]
        unless registry
          errors << "invalid predicate #{data['predicate'].inspect}: #{note.relative}"
          next
        end
        subject = vault.by_id[data["subject_id"]]
        object = vault.by_id[data["object_id"]]
        errors << "missing referenced subject: #{note.relative}" unless subject
        errors << "missing referenced object: #{note.relative}" unless object
        if subject && !Array(registry["subject_types"]).include?(subject.type)
          errors << "relationship direction violation: #{data['predicate']} subject #{subject.type}"
        end
        if object && !Array(registry["object_types"]).include?(object.type)
          errors << "relationship direction violation: #{data['predicate']} object #{object.type}"
        end
        if registry["symmetric"] && data["subject_id"].to_s >= data["object_id"].to_s
          errors << "symmetric relationship is not canonically ordered: #{note.relative}"
        end
        key = [data["subject_id"], data["predicate"], data["object_id"], data["relationship_status"]]
        errors << "duplicate semantic relationship: #{note.relative} and #{semantic[key]}" if semantic[key]
        semantic[key] = note.relative
      end
      metrics["invalid_predicates"] = errors.count { |error| error.start_with?("invalid predicate") }
      metrics["direction_violations"] = errors.count { |error| error.start_with?("relationship direction") }
      metrics["dangling_references"] = errors.count { |error| error.start_with?("missing referenced") }
      metrics["symmetry_violations"] = errors.count { |error| error.start_with?("symmetric relationship") }
    end

    def check_dates
      date_errors = 0
      vault.notes.each do |note|
        created = PKGAcceptance.scalar_time(note.data["created_at"])
        updated = PKGAcceptance.scalar_time(note.data["updated_at"])
        if created.nil? || updated.nil? || created > updated || created > FIXED_NOW + (366 * 86_400)
          errors << "impossible record dates: #{note.relative}"
          date_errors += 1
        end
        if note.data["valid_from"] && note.data["valid_to"]
          from = PKGAcceptance.scalar_time(note.data["valid_from"])
          to = PKGAcceptance.scalar_time(note.data["valid_to"])
          if from.nil? || to.nil? || from > to
            errors << "impossible validity interval: #{note.relative}"
            date_errors += 1
          end
        end
        next unless note.data["birth_date"]

        birth = PKGAcceptance.scalar_time(note.data["birth_date"])
        birth = birth.to_date if birth.respond_to?(:to_date)
        if birth.nil? || birth > FIXED_NOW.to_date
          errors << "impossible birth date: #{note.relative}"
          date_errors += 1
        end
      end
      metrics["impossible_dates"] = date_errors
    end

    def check_family_invariants
      parents = Hash.new { |hash, key| hash[key] = [] }
      spouses = Hash.new { |hash, key| hash[key] = [] }
      vault.notes_of("relationship").each do |note|
        next unless note.active? && note.data["relationship_status"] == "asserted"

        subject = note.data["subject_id"]
        object = note.data["object_id"]
        case note.data["predicate"]
        when "parent_of"
          errors << "parent_of self-cycle: #{note.relative}" if subject == object
          parents[subject] << object
        when "spouse_of"
          errors << "spouse_of self-link: #{note.relative}" if subject == object
          spouses[subject] << object
          spouses[object] << subject
        end
      end
      visiting = {}
      visited = {}
      detect_cycle = lambda do |node|
        return false if visited[node]
        return true if visiting[node]

        visiting[node] = true
        cycle = parents[node].any? { |child| detect_cycle.call(child) }
        visiting.delete(node)
        visited[node] = true
        cycle
      end
      parents.keys.each do |node|
        if detect_cycle.call(node)
          errors << "circular parent/child relationship involving #{node}"
          break
        end
      end
      spouses.each do |person, partners|
        errors << "invalid spouse relationships for #{person}: #{partners.uniq.length} active spouses" if partners.uniq.length > 1
      end
      metrics["family_invariant_violations"] = errors.count do |error|
        error.start_with?("parent_of", "spouse_of", "circular parent", "invalid spouse")
      end
    end

    def build_graph_metrics
      vault.notes.each { |note| adjacency[note.relative.sub(/\.md\z/, "")] ||= {} }
      degrees = adjacency.transform_values(&:length)
      visited = {}
      components = []
      adjacency.keys.each do |start|
        next if visited[start]

        stack = [start]
        size = 0
        until stack.empty?
          node = stack.pop
          next if visited[node]

          visited[node] = true
          size += 1
          adjacency[node].keys.each { |neighbor| stack << neighbor unless visited[neighbor] }
        end
        components << size
      end
      components.sort!.reverse!
      nodes = adjacency.length
      undirected_edges = degrees.values.sum / 2.0
      metrics["nodes"] = nodes
      metrics["graph_edges"] = undirected_edges.to_i
      metrics["average_degree"] = nodes.zero? ? 0.0 : degrees.values.sum.to_f / nodes
      metrics["maximum_degree"] = degrees.values.max || 0
      metrics["connected_components"] = components.length
      metrics["largest_component"] = components.first || 0
      metrics["largest_component_percent"] = nodes.zero? ? 0.0 : (components.first || 0) * 100.0 / nodes
      metrics["relationship_density"] = nodes < 2 ? 0.0 : undirected_edges / (nodes * (nodes - 1) / 2.0)
      metrics["orphans"] = degrees.count { |_node, degree| degree.zero? }
      metrics["under_connected"] = degrees.count { |_node, degree| degree < 2 }
      metrics["over_connected"] = degrees.count { |_node, degree| degree > 150 }
      metrics["huge_hubs"] = degrees.count { |_node, degree| degree > [150, nodes * 0.05].max }
      metrics["component_sizes"] = components
      metrics["top_nodes"] = degrees.sort_by { |path, degree| [-degree, path] }.first(15)
      metrics["entity_distribution"] = vault.notes.group_by(&:type).transform_values(&:length)
      metrics["relationship_distribution"] = vault.notes_of("relationship").group_by { |note| note.data["predicate"] }.transform_values(&:length)
      people = vault.notes_of("person").map(&:id).to_h { |id| [id, true] }
      companies = vault.notes_of("organization").select { |note| note.data["org_kind"] == "company" }.map(&:id).to_h { |id| [id, true] }
      semantic_degree = Hash.new(0)
      vault.notes_of("relationship").each do |note|
        semantic_degree[note.data["subject_id"]] += 1
        semantic_degree[note.data["object_id"]] += 1
      end
      metrics["most_connected_people"] = semantic_degree.select { |id, _| people[id] }
          .sort_by { |id, degree| [-degree, id] }.first(10)
      metrics["most_connected_companies"] = semantic_degree.select { |id, _| companies[id] }
          .sort_by { |id, degree| [-degree, id] }.first(10)
      meetings = vault.notes_of("interaction")
      metrics["average_meeting_size"] = meetings.empty? ? 0.0 : meetings.sum { |note| Array(note.data["participants"]).length }.to_f / meetings.length
      introductions = vault.notes_of("introduction")
      metrics["average_introductions_per_person"] = people.empty? ? 0.0 : introductions.length * 3.0 / people.length
    end

    def add_undirected(left, right)
      return if left == right

      adjacency[left][right] = true
      adjacency[right][left] = true
    end
  end

  def load_relationship_registry(root)
    registry = {}
    Dir.glob(File.join(root, "_System/Relationship Types/*.md")).sort.each do |path|
      data, = NoteIO.read(path)
      registry[data.fetch("predicate")] = data
    end
    registry
  end
end
