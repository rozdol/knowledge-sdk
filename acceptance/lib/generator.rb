# frozen_string_literal: true

require_relative "acceptance_support"

module PKGAcceptance
  class Generator
    TARGET_RELATIONSHIPS = 5_200
    ENTITY_TARGETS = {
      "person" => 300,
      "organization" => 140,
      "country" => 40,
      "city" => 70,
      "project" => 100,
      "interaction" => 800,
      "interest" => 200,
      "technology" => 150,
      "place" => 200,
      "event" => 80,
      "book" => 50,
      "language" => 12,
      "profession" => 20,
      "industry" => 12,
      "commitment" => 100,
      "follow-up" => 100,
      "introduction" => 150,
      "relationship" => TARGET_RELATIONSHIPS
    }.freeze

    attr_reader :source_root, :root, :seed, :run_id, :entities, :relationship_count

    def initialize(source_root:, root:, seed:, run_id:)
      @source_root = Pathname.new(source_root)
      @root = Pathname.new(root)
      @seed = seed
      @run_id = run_id
      @entities = Hash.new { |hash, key| hash[key] = [] }
      @counters = Hash.new(0)
      @relationship_keys = {}
      @relationship_count = 0
    end

    def generate!
      reset_root!
      copy_system_contract!
      generate_countries
      generate_cities
      generate_languages_professions_industries
      generate_people
      generate_organizations
      generate_interests
      generate_technologies
      generate_places
      generate_projects
      generate_events
      generate_books
      generate_interactions
      generate_commitments_and_followups
      generate_introductions
      generate_relationships
      assert_targets!
      root
    end

    private

    def reset_root!
      expanded = root.expand_path.to_s
      unless expanded.start_with?("/private/tmp/pkg-acceptance-", "/tmp/pkg-acceptance-")
        raise "refusing to replace unsafe acceptance path #{expanded}"
      end
      FileUtils.rm_rf(root)
      FileUtils.mkdir_p(root)
    end

    def copy_system_contract!
      plugin = source_root.join("plugins/personal-crm")
      FileUtils.mkdir_p(root.join("_System/Schema"))
      FileUtils.cp_r(plugin.join("schemas"), root.join("_System/Schema/Entity Types"))
      FileUtils.cp_r(plugin.join("relationship_types"), root.join("_System/Relationship Types"))
    end

    def base(type, name: nil, time: nil)
      index = @counters[type]
      @counters[type] += 1
      prefix = {
        "organization" => "org", "follow-up" => "followup"
      }.fetch(type, type)
      created = time || (FIXED_NOW - ((2_400 - (index % 2_000)) * 86_400))
      data = {
        "id" => "#{prefix}_#{PKGAcceptance.deterministic_ulid(seed, type, index, created)}",
        "type" => type,
        "schema_version" => SCHEMA_VERSION,
        "record_status" => "active",
        "created_at" => created.iso8601,
        "updated_at" => created.iso8601,
        "created_by" => "agent",
        "updated_by" => "agent",
        "created_by_run" => run_id,
        "updated_by_run" => run_id,
        "tags" => ["entity/#{type}"].map { |tag| tag.tr("_", "-") }
      }
      if name
        data["name"] = name
        data["aliases"] = []
      end
      data
    end

    def add_entity(type, folder, name, extra = {}, filename: nil, body: nil)
      data = base(type, name: name).merge(extra)
      filename ||= PKGAcceptance.safe_filename(name)
      relative = File.join(folder, "#{filename}.md")
      body ||= "# #{name}\n\n<!-- BEGIN AGENT-MANAGED: acceptance-fixture -->\nSynthetic acceptance fixture generated from seed #{seed}.\n<!-- END AGENT-MANAGED: acceptance-fixture -->\n"
      NoteIO.write(root.join(relative), data, body)
      entity = { "type" => type, "id" => data["id"], "name" => name, "path" => relative.sub(/\.md\z/, ""), "data" => data }
      entities[type] << entity
      entity
    end

    def ref(entity)
      PKGAcceptance.link(entity.fetch("path"), entity.fetch("name"))
    end

    def timestamp(days_ago, hour = 10)
      time = FIXED_NOW - (days_ago * 86_400)
      Time.new(time.year, time.month, time.day, hour, 0, 0, "+03:00").iso8601
    end

    def generate_countries
      countries = [
        ["United Kingdom", "GB"], ["United States", "US"], ["Germany", "DE"], ["France", "FR"],
        ["Spain", "ES"], ["Italy", "IT"], ["Netherlands", "NL"], ["Belgium", "BE"],
        ["Portugal", "PT"], ["Ireland", "IE"], ["Sweden", "SE"], ["Norway", "NO"],
        ["Denmark", "DK"], ["Finland", "FI"], ["Poland", "PL"], ["Austria", "AT"],
        ["Switzerland", "CH"], ["Greece", "GR"], ["Cyprus", "CY"], ["Estonia", "EE"],
        ["Canada", "CA"], ["Mexico", "MX"], ["Brazil", "BR"], ["Argentina", "AR"],
        ["Chile", "CL"], ["Australia", "AU"], ["New Zealand", "NZ"], ["Japan", "JP"],
        ["South Korea", "KR"], ["Singapore", "SG"], ["India", "IN"], ["Indonesia", "ID"],
        ["Israel", "IL"], ["United Arab Emirates", "AE"], ["South Africa", "ZA"], ["Kenya", "KE"],
        ["Nigeria", "NG"], ["Egypt", "EG"], ["Turkey", "TR"], ["Czechia", "CZ"]
      ]
      countries.each { |name, iso| add_entity("country", "Places/Countries", name, "iso_alpha2" => iso) }
    end

    def generate_cities
      names = [
        "London", "New York", "Berlin", "Paris", "Madrid", "Rome", "Amsterdam", "Brussels", "Lisbon", "Dublin",
        "Stockholm", "Oslo", "Copenhagen", "Helsinki", "Warsaw", "Vienna", "Zurich", "Athens", "Nicosia", "Tallinn",
        "Toronto", "Mexico City", "Sao Paulo", "Buenos Aires", "Santiago", "Sydney", "Auckland", "Tokyo", "Seoul", "Singapore",
        "Bengaluru", "Jakarta", "Tel Aviv", "Dubai", "Cape Town", "Nairobi", "Lagos", "Cairo", "Istanbul", "Prague",
        "Manchester", "San Francisco", "Munich", "Lyon", "Barcelona", "Milan", "Rotterdam", "Antwerp", "Porto", "Galway",
        "Gothenburg", "Bergen", "Aarhus", "Turku", "Krakow", "Salzburg", "Geneva", "Thessaloniki", "Limassol", "Tartu",
        "Vancouver", "Guadalajara", "Rio de Janeiro", "Cordoba", "Valparaiso", "Melbourne", "Wellington", "Osaka", "Busan", "Pune"
      ]
      names.each_with_index do |name, index|
        country = entities["country"][index % entities["country"].length]
        add_entity("city", "Places/Cities", name, "country" => ref(country))
      end
    end

    def generate_languages_professions_industries
      %w[English German French Spanish Italian Dutch Portuguese Swedish Polish Greek Japanese Korean].each_with_index do |name, index|
        add_entity("language", "Concepts/Languages", name, "iso_639_3" => format("x%02d", index))
      end
      ["Software Engineer", "Product Manager", "Designer", "Founder", "Investor", "Lawyer", "Accountant", "Researcher",
       "Data Scientist", "Consultant", "Teacher", "Doctor", "Architect", "Writer", "Journalist", "Chef", "Marketer",
       "Sales Leader", "Operations Manager", "Policy Analyst"].each do |name|
        add_entity("profession", "Concepts/Professions", name)
      end
      ["Artificial Intelligence", "Financial Technology", "Healthcare", "Climate Technology", "Education", "Cybersecurity",
       "Retail", "Hospitality", "Media", "Logistics", "Government", "Professional Services"].each do |name|
        add_entity("industry", "Concepts/Industries", name)
      end
    end

    def generate_people
      first_names = %w[
        Alex Maya Sofia Liam Emma Noah Olivia Lucas Ava Ethan Mia Leo Zoe Daniel Chloe Max Nora Samuel Elena David
        Aisha Omar Priya Arjun Mei Kenji Hana Diego Lucia Mateo Ana Victor Ingrid Lars Eva Tomasz Nadia Amir Leila
      ]
      last_names = %w[
        Smith Chen Garcia Patel Brown Wilson Martin Lee Taylor Anderson Thomas Jackson White Harris Thompson Moore Clark
        Lewis Young Walker Hall Allen King Wright Scott Green Baker Adams Nelson Hill Campbell Mitchell Roberts Carter
        Phillips Evans Turner Torres Parker Collins Edwards Stewart Morris Rogers Reed Cook Morgan Bell Murphy Bailey
      ]
      names = ["Self", "John Smith"]
      first_names.each do |first|
        last_names.each do |last|
          candidate = "#{first} #{last}"
          names << candidate unless names.include?(candidate)
          break if names.length == 300
        end
        break if names.length == 300
      end
      names.each_with_index do |name, index|
        slug = name.downcase.gsub(/[^a-z0-9]+/, ".").gsub(/\A\.|\.\z/, "")
        emails = ["#{slug}@example.test"]
        emails << "#{slug}@network.example" if (index % 4).zero?
        aliases = []
        aliases << name.split.first if index > 1 && (index % 5).zero?
        data = {
          "tier" => %w[inner active active dormant][index % 4],
          "sensitivity" => index.zero? ? "private" : "normal",
          "data_origin" => "mixed",
          "emails" => emails,
          "primary_email" => emails.first,
          "external_ids" => ["synthetic-person:#{format('%03d', index)}"],
          "birth_date" => format("%04d-%02d-%02d", 1955 + (index % 45), 1 + (index % 12), 1 + (index % 27)),
          "cadence_target_days" => [30, 60, 90, 180][index % 4],
          "contact_policy" => "normal",
          "life_status" => "living"
        }
        data["is_self"] = true if index.zero?
        person = add_entity("person", "People", name, data)
        unless aliases.empty?
          person["data"]["aliases"] = aliases
          NoteIO.write(root.join(person["path"] + ".md"), person["data"], "# #{name}\n")
        end
      end
    end

    def generate_organizations
      company_names = ["Microsoft"]
      prefixes = %w[Northstar Meridian Cedar Atlas Horizon Ember Bluewave Juniper Lattice Summit Harbor Mosaic Brightline
                    Alpine Kinetic Veridian Orbit Copper Willow Signal Nimbus Quartz Redwood Aurora Vector]
      suffixes = %w[Labs Systems Analytics Ventures Software Health Energy Robotics Foods Studio Works Cloud Security Mobility]
      prefixes.product(suffixes).each do |prefix, suffix|
        name = "#{prefix} #{suffix}"
        company_names << name unless company_names.include?(name)
        break if company_names.length == 120
      end
      company_names.each_with_index do |name, index|
        slug = name.downcase.gsub(/[^a-z0-9]+/, "")
        add_entity("organization", "Organizations", name,
                   "org_kind" => "company", "primary_domain" => "#{slug}.example", "external_ids" => ["synthetic-org:#{index}"])
      end
      kinds = %w[nonprofit government university fund community informal]
      20.times do |index|
        name = ["Global Builders Network", "European Research Council", "Founders Circle", "Open Cities Initiative"][index % 4]
        name = "#{name} #{index + 1}"
        add_entity("organization", "Organizations", name, "org_kind" => kinds[index % kinds.length])
      end
    end

    def generate_interests
      names = ["Skiing", "Japanese cuisine", "Knowledge Graphs", "Systems Thinking", "Hiking", "Photography", "Jazz",
               "Running", "Cycling", "Cooking", "Architecture", "Contemporary Art", "Sailing", "Chess", "Gardening"]
      categories = %w[sport cuisine topic hobby art practice]
      while names.length < 200
        names << "#{categories[names.length % categories.length].capitalize} Interest #{format('%03d', names.length + 1)}"
      end
      names.each_with_index do |name, index|
        add_entity("interest", "Concepts/Interests", name, "interest_kind" => categories[index % categories.length])
      end
    end

    def generate_technologies
      names = ["PostgreSQL", "Ruby", "Python", "TypeScript", "Kubernetes", "Terraform", "Obsidian", "Dataview",
               "React", "FastAPI", "Redis", "SQLite", "Docker", "AWS", "Machine Learning"]
      kinds = %w[database language framework platform tool protocol]
      while names.length < 150
        names << "#{kinds[names.length % kinds.length].capitalize} Technology #{format('%03d', names.length + 1)}"
      end
      names.each_with_index do |name, index|
        add_entity("technology", "Concepts/Technologies", name, "technology_kind" => kinds[index % kinds.length])
      end
    end

    def generate_places
      200.times do |index|
        restaurant = index < 120
        name = restaurant ? "#{%w[Oak Saffron Lantern Cedar Harbor Maple][index % 6]} Table #{format('%03d', index + 1)}" :
          "#{%w[Gallery Park Hotel Studio Museum Hub][index % 6]} #{format('%03d', index + 1)}"
        city = entities["city"][index % entities["city"].length]
        extra = { "place_kind" => restaurant ? "restaurant" : %w[cafe venue hotel office park][index % 5], "city" => ref(city) }
        extra["price_level"] = 1 + (index % 4) if restaurant
        add_entity("place", "Places/Locations", name, extra)
      end
    end

    def generate_projects
      100.times do |index|
        name = "#{%w[Aurora Bridge Compass Delta Echo Forge Grove Helix][index % 8]} Project #{format('%03d', index + 1)}"
        add_entity("project", "Work/Projects", name,
                   "project_status" => %w[idea planned active paused completed][index % 5])
      end
    end

    def generate_events
      80.times do |index|
        name = index.zero? ? "Web Summit 2025" : "#{%w[Technology Climate Founders Design Research][index % 5]} Forum #{2020 + (index % 7)}-#{format('%02d', index + 1)}"
        place = entities["place"][index % entities["place"].length]
        organizer = entities["organization"][index % entities["organization"].length]
        starts = FIXED_NOW - ((2_100 - index * 27) * 86_400)
        add_entity("event", "Interactions/Events", name,
                   "starts_at" => starts.iso8601, "event_kind" => %w[conference dinner meetup workshop][index % 4],
                   "place" => ref(place), "organizers" => [ref(organizer)])
      end
    end

    def generate_books
      50.times do |index|
        name = "#{%w[Practical Human Distributed Connected Resilient Thoughtful][index % 6]} Systems #{index + 1}"
        author = entities["person"][(index * 7 + 11) % entities["person"].length]
        add_entity("book", "Knowledge/Books", name, "authors" => [ref(author)])
      end
    end

    def generate_interactions
      800.times do |index|
        cluster = index % 20
        size = 2 + (index % 5)
        participants = size.times.map do |offset|
          person_index = (cluster * 15 + index / 20 + offset * 3) % entities["person"].length
          ref(entities["person"][person_index])
        end.uniq
        if participants.length < 2
          participants << ref(entities["person"][(index + 1) % entities["person"].length])
        end
        place = entities["place"][(index * 13) % entities["place"].length]
        started = FIXED_NOW - ((2_350 - index * 2) * 86_400)
        name = "#{started.strftime('%Y-%m-%d')} - Network Meeting #{format('%04d', index + 1)}"
        add_entity("interaction", "Interactions/Meetings", name,
                   "starts_at" => started.iso8601, "participants" => participants,
                   "interaction_kind" => "meeting", "contact_weight" => index % 5 == 0 ? "incidental" : "substantive",
                   "sensitivity" => "normal", "data_origin" => "mixed", "place" => ref(place))
      end
    end

    def generate_commitments_and_followups
      100.times do |index|
        promisor = entities["person"][index % entities["person"].length]
        recipient = entities["person"][(index * 7 + 1) % entities["person"].length]
        made = (FIXED_NOW - ((500 - index * 3) * 86_400)).to_date
        commitment = add_entity("commitment", "Commitments/Promises", "#{made} - Follow through #{format('%03d', index + 1)}",
                                "tags" => ["entity/commitment", "commitment/promise"],
                                "commitment_kind" => "promise", "promisor" => ref(promisor), "promise_to" => ref(recipient),
                                "action" => "Send the agreed project update #{index + 1}",
                                "commitment_status" => index.positive? && index % 4 == 0 ? "fulfilled" : "open", "made_on" => made.iso8601,
                                "due_on" => (made + 30).iso8601, "sensitivity" => "normal", "data_origin" => "mixed")
        owner = index % 3 == 0 ? entities["person"].first : promisor
        add_entity("follow-up", "Commitments/Follow-ups", "Follow-up #{format('%03d', index + 1)}",
                   "owner" => ref(owner), "action" => "Check progress on commitment #{index + 1}",
                   "followup_status" => %w[open scheduled waiting snoozed done][index % 5],
                   "due_on" => (made + 37).iso8601, "priority" => %w[low normal high][index % 3],
                   "with" => ref(recipient), "related_to" => [ref(commitment)],
                   "sensitivity" => "normal", "data_origin" => "mixed")
      end
    end

    def generate_introductions
      150.times do |index|
        introducer = entities["person"][(index * 11 + 2) % entities["person"].length]
        left = index.zero? ? entities["person"].first : entities["person"][(index * 5 + 3) % entities["person"].length]
        right = index.zero? ? entities["person"][1] : entities["person"][(index * 7 + 17) % entities["person"].length]
        right = entities["person"][(index * 7 + 18) % entities["person"].length] if right["id"] == left["id"]
        ordered = [left, right].sort_by { |person| person["id"] }
        data = base("introduction").merge(
          "tags" => ["entity/introduction"],
          "introducer" => ref(introducer), "introducer_id" => introducer["id"],
          "person_a" => ref(ordered[0]), "person_a_id" => ordered[0]["id"],
          "person_b" => ref(ordered[1]), "person_b_id" => ordered[1]["id"],
          "assertion_status" => "asserted", "confidence" => "confirmed", "asserted_by" => "agent",
          "asserted_by_run" => run_id, "asserted_at" => timestamp(1_500 - index * 5),
          "occurred_on" => (FIXED_NOW.to_date - (1_500 - index * 5)).iso8601,
          "sensitivity" => "normal", "data_origin" => "mixed"
        )
        relative = "Interactions/Introductions/#{data['id']}.md"
        NoteIO.write(root.join(relative), data, "<!-- BEGIN AGENT-MANAGED: acceptance-fixture -->\nSynthetic introduction.\n<!-- END AGENT-MANAGED: acceptance-fixture -->\n")
        entities["introduction"] << { "type" => "introduction", "id" => data["id"], "name" => data["id"], "path" => relative.sub(/\.md\z/, ""), "data" => data }
      end
    end

    def generate_relationships
      organizations = entities["organization"]
      countries = entities["country"]
      cities = entities["city"]
      technologies = entities["technology"]
      projects = entities["project"]
      people = entities["person"]
      interests = entities["interest"]
      languages = entities["language"]
      professions = entities["profession"]
      industries = entities["industry"]
      places = entities["place"]
      events = entities["event"]
      books = entities["book"]

      organizations.each_with_index do |organization, index|
        add_relationship(organization, "headquartered_in", cities[index % cities.length])
        add_relationship(organization, "incorporated_in", countries[index % countries.length])
        add_relationship(organization, "uses", technologies[index % technologies.length], "strength" => "regular")
      end
      projects.each_with_index do |project, index|
        add_relationship(project, "uses", technologies[(index * 3) % technologies.length], "strength" => "regular")
        add_relationship(people[(index * 7) % people.length], "contributes_to", project, "role" => "Contributor")
        add_relationship(people[(index * 7 + 1) % people.length], "leads", project, "literal_title" => "Project Lead")
      end
      technologies.each_with_index do |technology, index|
        next if index < organizations.length || (index % 3).zero?

        add_relationship(projects[index % projects.length], "develops", technology, "role" => "maintainer")
      end
      industries.each_with_index do |industry, index|
        add_relationship(people[index], "expert_in", industry, "proficiency" => "working")
      end
      people.each_with_index do |person, index|
        add_relationship(person, "born_in", cities[(index * 7) % cities.length])
        add_relationship(person, "lives_in", cities[index % cities.length], "valid_from" => format("%04d-01-01", 2014 + (index % 10)))
        add_relationship(person, "works_for", organizations[index % 120],
                         "valid_from" => format("%04d-01-01", 2021 + (index % 5)), "employment_kind" => "employee",
                         "literal_title" => %w[Engineer Manager Director Analyst Designer][index % 5])
        if index.even?
          add_relationship(person, "works_for", organizations[(index + 37) % 120],
                           "valid_from" => format("%04d-01-01", 2015 + (index % 4)),
                           "valid_to" => format("%04d-12-31", 2019 + (index % 2)), "employment_kind" => "employee")
        end
        add_relationship(person, "speaks", languages[index % languages.length], "proficiency" => "fluent")
        add_relationship(person, "speaks", languages[(index + 5) % languages.length], "proficiency" => "conversational") if index.even?
        add_relationship(person, "has_profession", professions[index % professions.length])
        2.times { |offset| add_relationship(person, "likes", interests[(index * 2 + offset) % interests.length], "strength" => "regular") }
        target = [interests, technologies, industries, projects, books][index % 5]
        add_relationship(person, "interested_in", target[(index * 3) % target.length], "strength" => "regular")
        add_relationship(person, "visited", places[(index * 11) % places.length], "visit_kind" => "travel")
        add_relationship(person, "attended", events[index % events.length])
        add_relationship(person, "read", books[index % books.length]) if index.even?
        add_relationship(person, "expert_in", industries[index % industries.length], "proficiency" => "working") if index.even?
      end
      100.times do |index|
        add_relationship(people[index], "founded", organizations[(index * 7 + 3) % 120], "role" => "Co-founder")
        add_relationship(people[(index + 50) % people.length], "advisor_to", organizations[(index * 11 + 5) % 120], "domain" => "strategy")
        add_relationship(people[(index + 100) % people.length], "invested_in", organizations[(index * 13 + 7) % 120], "strength" => "minor")
      end
      50.times do |index|
        add_relationship(people[20 + index * 2], "spouse_of", people[21 + index * 2], "relationship_kind" => "married")
      end
      100.times do |index|
        add_relationship(people[index], "parent_of", people[150 + index], "relationship_kind" => "biological")
      end
      300.times do |index|
        add_relationship(people[index], "knows", people[(index + 1) % people.length], "connection_origin" => "professional network")
      end
      100.times do |index|
        add_relationship(people[index], "friend_of", people[(index + 9) % people.length], "closeness" => "regular")
      end
      100.times do |index|
        break if relationship_count >= TARGET_RELATIONSHIPS
        add_relationship(people[index], "mentor_of", people[index + 120], "domain" => "career")
      end
      offset = 2
      while relationship_count < TARGET_RELATIONSHIPS
        300.times do |index|
          break if relationship_count >= TARGET_RELATIONSHIPS
          add_relationship(people[index], "knows", people[(index + offset) % people.length], "connection_origin" => "shared community")
        end
        offset += 1
        raise "unable to fill relationship target" if offset > 100
      end
    end

    def add_relationship(subject, predicate, object, extras = {})
      return false if relationship_count >= TARGET_RELATIONSHIPS

      registry = relationship_registry.fetch(predicate)
      if registry["symmetric"] && subject["id"] > object["id"]
        subject, object = object, subject
      end
      return false if subject["id"] == object["id"]

      key = [subject["id"], predicate, object["id"], "asserted"]
      return false if @relationship_keys[key]

      @relationship_keys[key] = true
      data = base("relationship").merge(
        "tags" => ["entity/relationship", "relationship/#{predicate.tr('_', '-')}"],
        "subject" => ref(subject), "subject_id" => subject["id"], "predicate" => predicate,
        "object" => ref(object), "object_id" => object["id"], "relationship_status" => "asserted",
        "confidence" => "confirmed", "asserted_by" => "agent", "asserted_by_run" => run_id,
        "asserted_at" => timestamp(1_800 - (relationship_count % 1_700)), "sensitivity" => "normal", "data_origin" => "mixed"
      ).merge(extras)
      relative = "Relationships/#{predicate}/#{data['id']}.md"
      NoteIO.write(root.join(relative), data, "")
      entities["relationship"] << { "type" => "relationship", "id" => data["id"], "name" => data["id"], "path" => relative.sub(/\.md\z/, ""), "data" => data }
      @relationship_count += 1
      true
    end

    def relationship_registry
      @relationship_registry ||= PKGAcceptance.load_relationship_registry(root)
    end

    def assert_targets!
      actual = entities.transform_values(&:length)
      ENTITY_TARGETS.each do |type, expected|
        raise "#{type}: expected #{expected}, generated #{actual[type] || 0}" unless actual[type] == expected
      end
      restaurants = entities["place"].count { |place| place["data"]["place_kind"] == "restaurant" }
      raise "expected 120 restaurants, generated #{restaurants}" unless restaurants == 120
      companies = entities["organization"].count { |organization| organization["data"]["org_kind"] == "company" }
      raise "expected 120 companies, generated #{companies}" unless companies == 120
    end
  end
end
