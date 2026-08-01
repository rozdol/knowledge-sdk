# frozen_string_literal: true

require_relative "acceptance_support"

module PKGAcceptance
  class Mutations
    attr_reader :root, :seed, :run_id

    def initialize(root:, seed:, run_id:)
      @root = Pathname.new(root)
      @seed = seed
      @run_id = run_id
      @sequence = 90_000
    end

    def vault
      @vault ||= Vault.new(root)
    end

    def validate!
      vault.reload.validate!
    end

    def common(type, name: nil, namespace: "simulation")
      @sequence += 1
      id_prefix = { "organization" => "org", "follow-up" => "followup" }.fetch(type, type)
      data = {
        "id" => "#{id_prefix}_#{PKGAcceptance.deterministic_ulid(seed, "#{namespace}-#{type}", @sequence)}",
        "type" => type, "schema_version" => 1, "record_status" => "active",
        "created_at" => FIXED_NOW.iso8601, "updated_at" => FIXED_NOW.iso8601,
        "created_by" => "agent", "updated_by" => "agent", "created_by_run" => run_id,
        "updated_by_run" => run_id, "tags" => ["entity/#{type}".tr("_", "-")]
      }
      data.merge!("name" => name, "aliases" => []) if name
      data
    end

    def find(type, name = nil)
      vault.reload.notes_of(type).find { |note| name.nil? || note.data["name"] == name }
    end

    def rename_note(note, new_name)
      old_name = note.data["name"]
      old_target = note.relative.sub(/\.md\z/, "")
      folder = File.dirname(note.relative)
      new_relative = File.join(folder, "#{PKGAcceptance.safe_filename(new_name)}.md")
      new_target = new_relative.sub(/\.md\z/, "")
      raise "rename collision #{new_relative}" if root.join(new_relative).exist?

      NoteIO.update(note.path) do |data|
        data["aliases"] = (Array(data["aliases"]) + [old_name]).uniq
        data["name"] = new_name
        data["updated_at"] = FIXED_NOW.iso8601
        data["updated_by"] = "agent"
        data["updated_by_run"] = run_id
      end
      FileUtils.mv(note.path, root.join(new_relative))
      rewrite_links(old_target, new_target, new_name)
      @vault = nil
      new_relative
    end

    def rewrite_links(old_target, new_target, new_label)
      Dir.glob(root.join("**/*.md").to_s).each do |filename|
        next if filename.include?("/_System/")

        begin
          data, body = NoteIO.read(filename)
        rescue StandardError
          next
        end
        changed = false
        data.each do |key, value|
          values = value.is_a?(Array) ? value : [value]
          replacement = values.map do |item|
            if PKGAcceptance.link_target(item) == old_target
              changed = true
              PKGAcceptance.link(new_target, new_label)
            else
              item
            end
          end
          data[key] = value.is_a?(Array) ? replacement : replacement.first
        end
        NoteIO.write(filename, data, body) if changed
      end
    end

    def write_relationship(subject, predicate, object, namespace: "simulation")
      registry = relationship_registry.fetch(predicate)
      if registry["symmetric"] && subject.id > object.id
        subject, object = object, subject
      end
      data = common("relationship", namespace: namespace).merge(
        "tags" => ["entity/relationship", "relationship/#{predicate.tr('_', '-')}"],
        "subject" => PKGAcceptance.link(subject.relative.sub(/\.md\z/, ""), subject.data["name"]), "subject_id" => subject.id,
        "predicate" => predicate,
        "object" => PKGAcceptance.link(object.relative.sub(/\.md\z/, ""), object.data["name"]), "object_id" => object.id,
        "relationship_status" => "asserted", "confidence" => "confirmed", "asserted_by" => "agent",
        "asserted_by_run" => run_id, "asserted_at" => FIXED_NOW.iso8601,
        "sensitivity" => "normal", "data_origin" => "mixed"
      )
      relative = "Relationships/#{predicate}/#{data['id']}.md"
      NoteIO.write(root.join(relative), data, "")
      @vault = nil
      root.join(relative)
    end

    def relationship_registry
      @relationship_registry ||= PKGAcceptance.load_relationship_registry(root)
    end
  end

  class AISimulation
    attr_reader :mutations, :results

    def initialize(root:, seed:, run_id:)
      @mutations = Mutations.new(root: root, seed: seed, run_id: run_id)
      @results = []
    end

    def run!
      operation("Create person") { create_person }
      operation("Merge duplicate") { merge_duplicate }
      operation("Update company") { update_company }
      operation("Rename company") { rename_company }
      operation("Add meeting") { add_meeting }
      operation("Move project") { move_project }
      operation("Archive entity") { archive_entity }
      operation("Link entities") { link_entities }
      self
    end

    def pass?
      results.all? { |result| result["error"].nil? }
    end

    private

    def operation(name)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      error = nil
      begin
        yield
        validation = mutations.validate!
      rescue StandardError => exception
        validation = nil
        error = "#{exception.class}: #{exception.message}"
      end
      results << {
        "operation" => name,
        "seconds" => Process.clock_gettime(Process::CLOCK_MONOTONIC) - started,
        "validation" => validation && validation["stdout"],
        "error" => error
      }
    end

    def create_person
      data = mutations.common("person", name: "AI Simulation Contact").merge(
        "tier" => "active", "sensitivity" => "normal", "data_origin" => "given_by_subject",
        "emails" => ["ai.simulation.contact@example.test"], "primary_email" => "ai.simulation.contact@example.test"
      )
      NoteIO.write(mutations.root.join("People/AI Simulation Contact.md"), data, "# AI Simulation Contact\n")
    end

    def merge_duplicate
      target = mutations.find("person", "AI Simulation Contact")
      data = mutations.common("person", name: "AI Simulation Contact Duplicate").merge(
        "record_status" => "merged",
        "merged_into" => PKGAcceptance.link(target.relative.sub(/\.md\z/, ""), target.data["name"]),
        "emails" => ["ai.simulation.contact@example.test"]
      )
      NoteIO.write(mutations.root.join("People/AI Simulation Contact Duplicate.md"), data, "")
    end

    def update_company
      company = mutations.find("organization", "Northstar Labs") || mutations.find("organization")
      NoteIO.update(company.path) do |data|
        data["website"] = "https://updated-company.example"
        data["updated_at"] = FIXED_NOW.iso8601
        data["updated_by_run"] = mutations.run_id
      end
    end

    def rename_company
      company = mutations.vault.reload.notes_of("organization").find { |note| note.data["name"] != "Microsoft" }
      mutations.rename_note(company, "#{company.data['name']} International")
    end

    def add_meeting
      people = mutations.vault.reload.notes_of("person").select(&:active?).first(3)
      data = mutations.common("interaction", name: "2026-07-29 - AI Simulation Meeting").merge(
        "starts_at" => FIXED_NOW.iso8601,
        "participants" => people.map { |person| PKGAcceptance.link(person.relative.sub(/\.md\z/, ""), person.data["name"]) },
        "interaction_kind" => "meeting", "contact_weight" => "substantive",
        "sensitivity" => "normal", "data_origin" => "mixed"
      )
      NoteIO.write(mutations.root.join("Interactions/Meetings/2026-07-29 - AI Simulation Meeting.md"), data, "# AI Simulation Meeting\n")
    end

    def move_project
      project = mutations.find("project")
      mutations.rename_note(project, "#{project.data['name']} - Portfolio")
    end

    def archive_entity
      meeting = mutations.find("interaction", "2026-07-29 - AI Simulation Meeting")
      NoteIO.update(meeting.path) do |data|
        data["record_status"] = "archived"
        data["updated_at"] = FIXED_NOW.iso8601
        data["updated_by_run"] = mutations.run_id
      end
    end

    def link_entities
      person = mutations.find("person", "AI Simulation Contact")
      technology = mutations.find("technology", "PostgreSQL")
      mutations.write_relationship(person, "uses", technology)
    end
  end

  class StressSimulation
    BATCH_SIZE = 100

    attr_reader :mutations, :operation_count, :results, :operation_distribution

    def initialize(root:, seed:, run_id:, operation_count: 2_000)
      @mutations = Mutations.new(root: root, seed: seed, run_id: run_id)
      @seed = seed
      @operation_count = operation_count
      @results = []
      @operation_distribution = Hash.new(0)
      @created_meetings = []
      @created_relationships = []
      @semantic_keys = {}
      mutations.vault.notes_of("relationship").each do |note|
        @semantic_keys[[note.data["subject_id"], note.data["predicate"], note.data["object_id"]]] = true
      end
      refresh_cache
    end

    def run!
      random = Random.new(Digest::SHA256.hexdigest(@seed).to_i(16) % (2**31))
      operation_count.times do |index|
        perform_operation(index, random)
        next unless ((index + 1) % BATCH_SIZE).zero? || index + 1 == operation_count

        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        error = nil
        begin
          validation = mutations.validate!
        rescue StandardError => exception
          validation = nil
          error = "#{exception.class}: #{exception.message}"
        end
        results << {
          "batch" => results.length + 1, "operations" => index + 1,
          "seconds" => Process.clock_gettime(Process::CLOCK_MONOTONIC) - started,
          "validation" => validation && validation["stdout"], "error" => error
        }
        raise error if error
      end
      self
    end

    def pass?
      results.all? { |result| result["error"].nil? }
    end

    private

    def perform_operation(index, random)
      if ((index + 1) % 500).zero?
        create_merged_duplicate(index)
        operation_distribution["merge"] += 1
        return
      end
      if ((index + 1) % 200).zero?
        rename_person(index)
        operation_distribution["rename"] += 1
        return
      end

      action = random.rand(5)
      case action
      when 0
        update_metadata(random)
        operation_distribution["update_metadata"] += 1
      when 1
        create_meeting(index, random)
        operation_distribution["create_meeting"] += 1
      when 2
        archive_meeting(random)
        operation_distribution["archive_meeting"] += 1
      when 3
        add_relationship(index, random)
        operation_distribution["add_relationship"] += 1
      when 4
        remove_relationship
        operation_distribution["remove_relationship"] += 1
      end
    end

    def update_metadata(random)
      note = @metadata_notes[random.rand(@metadata_notes.length)]
      return unless note.path.exist?

      NoteIO.update(note.path) do |data|
        data["updated_at"] = FIXED_NOW.iso8601
        data["updated_by"] = "agent"
        data["updated_by_run"] = mutations.run_id
      end
    end

    def create_meeting(index, random)
      selected = [@people[random.rand(@people.length)], @people[random.rand(@people.length)]].uniq
      selected << @people[(random.rand(@people.length) + 1) % @people.length] while selected.length < 2
      name = "Stress Meeting #{format('%04d', index + 1)}"
      data = mutations.common("interaction", name: name, namespace: "stress").merge(
        "starts_at" => FIXED_NOW.iso8601,
        "participants" => selected.map { |person| PKGAcceptance.link(person.relative.sub(/\.md\z/, ""), person.data["name"]) },
        "interaction_kind" => "meeting", "contact_weight" => "substantive",
        "sensitivity" => "normal", "data_origin" => "mixed"
      )
      path = mutations.root.join("Interactions/Meetings/#{name}.md")
      NoteIO.write(path, data, "")
      @created_meetings << path
    end

    def archive_meeting(random)
      existing = @created_meetings.select(&:exist?)
      note_path = existing.empty? ? @base_meetings[random.rand(@base_meetings.length)] : existing[random.rand(existing.length)]
      NoteIO.update(note_path) do |data|
        data["record_status"] = "archived"
        data["updated_at"] = FIXED_NOW.iso8601
        data["updated_by_run"] = mutations.run_id
      end
    end

    def add_relationship(index, random)
      20.times do
        person = @people[random.rand(@people.length)]
        technology = @technologies[random.rand(@technologies.length)]
        key = [person.id, "uses", technology.id]
        next if @semantic_keys[key]

        path = mutations.write_relationship(person, "uses", technology, namespace: "stress-#{index}")
        @semantic_keys[key] = true
        @created_relationships << [path, key]
        return
      end
      update_metadata(random)
    end

    def remove_relationship
      pair = @created_relationships.pop
      return unless pair

      path, key = pair
      FileUtils.rm_f(path)
      @semantic_keys.delete(key)
    end

    def rename_person(index)
      candidates = @people.select do |note|
        note.active? && !["Self", "John Smith", "AI Simulation Contact"].include?(note.data["name"])
      end
      note = candidates[index % candidates.length]
      mutations.rename_note(note, "#{note.data['name']} R#{index + 1}")
      refresh_cache
    end

    def create_merged_duplicate(index)
      target = @people.find(&:active?)
      name = "Stress Merged Duplicate #{index + 1}"
      data = mutations.common("person", name: name, namespace: "stress").merge(
        "record_status" => "merged",
        "merged_into" => PKGAcceptance.link(target.relative.sub(/\.md\z/, ""), target.data["name"])
      )
      NoteIO.write(mutations.root.join("People/#{name}.md"), data, "")
    end

    def refresh_cache
      vault = mutations.vault.reload
      @people = vault.notes_of("person").select(&:active?)
      @technologies = vault.notes_of("technology").select(&:active?)
      @base_meetings = vault.notes_of("interaction").first(800).map(&:path)
      @metadata_notes = vault.notes.reject { |note| note.type == "relationship" && note.data["record_status"] == "merged" }
    end
  end
end
