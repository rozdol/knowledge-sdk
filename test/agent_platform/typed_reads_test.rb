# frozen_string_literal: true
require_relative "test_support"

class TypedReadsTest < Minitest::Test
  ADA = "person_00000000000000000000000002"
  HIDDEN = "person_00000000000000000000000003"
  CAPTURE = "capture_00000000000000000000000004"
  OTHER = "person_00000000000000000000000005"
  NOW = Time.utc(2026, 10, 25, 12)
  GRANTS = %w[graph:read capture:read intelligence:read activity:read].freeze

  def fixture
    with_schema_vault do |root|
      engine = KnowledgeGraph::Engine.new(vault_root: root, run_id: AgentPlatformTestSupport::RUN_ID, clock: -> { NOW })
      [[ADA, "Ada Synthetic", "private"], [HIDDEN, "Hidden Contact", "restricted"], [OTHER, "Other Synthetic", "private"]].each do |id, name, sensitivity|
        engine.execute(KnowledgeGraph::CreateEntity.new(entity_type: "person", attributes: {
          id: id, name: name, aliases: [], tier: "active", sensitivity: sensitivity, data_origin: "public",
          emails: ["synthetic@example.test"], phones: ["+15550000001"]
        }))
      end
      reader = KnowledgeGraph::GraphReader.new(vault_root: root)
      engine.execute(KnowledgeGraph::RecordInteraction.new(attributes: {
        name: "Visible call", starts_at: "2026-10-24T12:00:00Z", participants: [reader.find(ADA).link, reader.find(OTHER).link],
        interaction_kind: "call", contact_weight: "substantive", sensitivity: "private", data_origin: "public"
      }))
      engine.execute(KnowledgeGraph::RecordInteraction.new(attributes: {
        name: "Hidden endpoint call", starts_at: "2026-10-25T12:00:00Z", participants: [reader.find(ADA).link, reader.find(HIDDEN).link],
        interaction_kind: "call", contact_weight: "substantive", sensitivity: "private", data_origin: "public"
      }))
      engine.execute(KnowledgeGraph::AddRelationship.new(source: ADA, predicate: "knows", target: OTHER))
      engine.execute(KnowledgeGraph::AddRelationship.new(source: OTHER, predicate: "knows", target: HIDDEN))
      engine.execute(KnowledgeGraph::CreateCapture.new(capture_id: CAPTURE, kind: "note", title: "Literal archived idea",
        body: "**Research** for #{reader.find(HIDDEN).link} and #{reader.find(ADA).link}. <img src=x> No execution.",
        captured_at: NOW.iso8601, language: "en", source: "test"))
      engine.execute(KnowledgeGraph::LinkCapture.new(capture_id: CAPTURE, related_contacts: [HIDDEN, ADA]))
      engine.execute(KnowledgeGraph::CreateCapture.new(capture_id: "capture_00000000000000000000000006", kind: "note", title: "Safe independent Capture", body: "Synthetic history note.", captured_at: NOW.iso8601, language: "en", source: "test"))
      engine.execute(KnowledgeGraph::CreateCapture.new(capture_id: "capture_00000000000000000000000001", kind: "note", title: "Hidden Capture", body: "Restricted synthetic content.", captured_at: NOW.iso8601, language: "en", source: "test", sensitivity: "restricted"))
      yield root, engine
    end
  end

  def read(gateway, agent, name, args = {})
    response = invoke(gateway, agent, "kg.#{name}", args)
    assert response.success?, response.to_h.inspect
    response.payload
  end

  def test_visible_first_lists_detail_and_keyset_pagination
    fixture do |root, _engine|
      gateway, agent = build_gateway(root, permissions: GRANTS, clock: -> { NOW })
      first = read(gateway, agent, "contacts.list", "limit" => 1)
      assert_equal [ADA], first.dig("data", "items").map { |item| item["id"] }
      next_page = read(gateway, agent, "contacts.list", "limit" => 1, "after" => first.dig("data", "page", "after"))
      assert_equal [OTHER], next_page.dig("data", "items").map { |item| item["id"] }
      assert_equal first["source_version"], next_page["source_version"]
      detail = read(gateway, agent, "contacts.get", "entity_id" => ADA)
      refute_includes JSON.generate(detail), "synthetic@example.test"
      hidden = invoke(gateway, agent, "kg.contacts.get", "entity_id" => HIDDEN)
      absent = invoke(gateway, agent, "kg.contacts.get", "entity_id" => "person_00000000000000000000000009")
      assert_equal hidden.errors, absent.errors
      refute hidden.success?
      _, private_agent = build_gateway(root, permissions: GRANTS + ["graph:private"])
      assert_equal ["synthetic@example.test"], read(gateway, private_agent, "contacts.get", "entity_id" => ADA).dig("data", "item", "emails")
    end
  end

  def test_rank_formula_and_hidden_only_edits_do_not_change_visible_scores_or_versions
    fixture do |root, engine|
      gateway, agent = build_gateway(root, permissions: GRANTS, clock: -> { NOW })
      before = read(gateway, agent, "contacts.top", "as_of" => "2026-10-25")
      assert_equal "partial", before["status"]
      assert_nil before.dig("data", "self_id")
      ada = before.dig("data", "items").find { |item| item["id"] == ADA }.fetch("interaction")
      assert_equal 1, ada["interaction_count"]
      assert_equal "2026-10-24T12:00:00Z", ada["latest_at"]
      assert_in_delta 0.6 * ada["recency_score"] + 0.4 * ada["interaction_frequency"], ada["score"], 0.000001
      engine.execute(KnowledgeGraph::UpdateEntity.new(entity_id: HIDDEN, changes: { aliases: ["Hidden changed"] }))
      after = read(gateway, agent, "contacts.top", "as_of" => "2026-10-25")
      assert_equal before, after
      refute_includes JSON.generate(after), HIDDEN
    end
  end

  def test_relations_use_visible_snapshot_before_traversal
    fixture do |root, _engine|
      gateway, agent = build_gateway(root, permissions: GRANTS, clock: -> { NOW })
      result = read(gateway, agent, "contacts.relations", "entity_id" => ADA, "depth" => 2)
      assert_equal [ADA, OTHER], result.dig("data", "nodes").map { |item| item["id"] }
      assert_equal 1, result.dig("data", "edges").length
      refute_includes JSON.generate(result), HIDDEN
    end
  end

  def test_capture_literal_filters_safe_rendition_links_and_activity
    fixture do |root, _engine|
      gateway, agent = build_gateway(root, permissions: GRANTS, clock: -> { NOW + 1 })
      result = read(gateway, agent, "captures.list", "query" => "archived idea")
      assert_equal [CAPTURE], result.dig("data", "items").map { |item| item["id"] }
      assert_equal "linked", result.dig("data", "items", 0, "status")
      assert_equal [ADA], result.dig("data", "items", 0, "links")
      limited = read(gateway, agent, "captures.list", "limit" => 1)
      assert_equal [CAPTURE], limited.dig("data", "items").map { |item| item["id"] }
      hidden = invoke(gateway, agent, "kg.captures.get", "capture_id" => "capture_00000000000000000000000001")
      assert_equal "PolicyDenied", hidden.errors.first["code"]
      detail = read(gateway, agent, "captures.get", "capture_id" => CAPTURE)
      refute_includes JSON.generate(detail), "Hidden Contact"
      refute_includes detail.dig("data", "item", "text"), "[["
      refute_includes detail.dig("data", "item", "text"), "<img"
      assert_includes detail.dig("data", "item", "text"), "Ada Synthetic"
      # A permitted Capture may contain only a hidden structural link. Its safe
      # rendition is empty; metadata remains readable without a fake text match.
      hidden_link = KnowledgeGraph::GraphReader.new(vault_root: root).find(HIDDEN).link
      engine = KnowledgeGraph::Engine.new(vault_root: root, run_id: AgentPlatformTestSupport::RUN_ID, clock: -> { NOW })
      empty_id = "capture_00000000000000000000000008"
      engine.execute(KnowledgeGraph::CreateCapture.new(capture_id: empty_id, kind: "note", title: "Metadata only", body: hidden_link, captured_at: NOW.iso8601, language: "en", source: "test"))
      empty = read(gateway, agent, "captures.get", "capture_id" => empty_id)
      assert_equal "", empty.dig("data", "item", "text")
      assert_equal "ok", empty["status"]

      history = nil
      refuse_writer = ->(**_options) { flunk "Activity browsing constructed a writer" }
      KnowledgeGraph::Engine.stub(:new, refuse_writer) do
        KnowledgeExtraction::ProposalStore.stub(:new, refuse_writer) do
          StructuredDataset::Engine.stub(:new, refuse_writer) do
            history = read(gateway, agent, "activity.list", "from" => "2026-10-25T00:00:00Z", "to" => "2026-10-26T00:00:00Z")
          end
        end
      end
      refute_includes JSON.generate(history), HIDDEN
      refute_includes JSON.generate(history), "Hidden endpoint"
      refute_includes JSON.generate(history), "undo_available"
      assert_includes history["limitations"], "dataset_activity_not_available"
      assert history.dig("data", "items").any? { |item| item["source"] == "capture" }
    end
  end

  def test_visible_dataset_storage_failures_and_hidden_storage_changes_remain_safe
    fixture do |root, _engine|
      gateway, agent = build_gateway(root, permissions: GRANTS + ["dataset:read"], clock: -> { NOW + 1 })
      before = read(gateway, agent, "activity.list")
      writer = StructuredDataset::Engine.new(vault_root: root, clock: -> { NOW })
      writer.create("weight", sensitivity: "restricted")
      assert_equal before, read(gateway, agent, "activity.list")
      writer.create("blood_pressure", sensitivity: "private")
      db_path = File.join(root, KnowledgeSDK::DATASET_PATH)
      connection = SQLite3::Database.new(db_path)
      connection.execute("PRAGMA user_version = 1"); connection.close
      bytes = File.binread(db_path)
      history = read(gateway, agent, "activity.list")
      assert_includes history["limitations"], "dataset_upgrade_required"
      assert_equal bytes, File.binread(db_path)
    end
  end

  def test_traversal_bounds_are_partial_and_unknown_ranking_stays_null
    with_schema_vault do |root|
      records = (1..105).map do |n|
        id = "person_#{n.to_s.rjust(26, '0')}"
        KnowledgeIntelligence::RecordSnapshot.new(id: id, type: "person", name: "Synthetic #{n}", path: "People/#{n}.md",
          data: { "id" => id, "type" => "person", "name" => "Synthetic #{n}", "record_status" => "active", "sensitivity" => "private" })
      end
      root_id = records.first.id
      records += records.drop(1).each_with_index.map do |target, n|
        id = "rel_#{n.to_s.rjust(26, '0')}"
        KnowledgeIntelligence::RecordSnapshot.new(id: id, type: "relationship", name: nil, path: "Relations/#{n}.md",
          data: { "id" => id, "type" => "relationship", "record_status" => "active", "relationship_status" => "asserted",
            "subject_id" => root_id, "object_id" => target.id, "predicate" => "knows" })
      end
      graph = KnowledgeIntelligence::GraphSnapshot.new(records)
      gateway, agent = build_gateway(root, permissions: GRANTS, clock: -> { NOW })
      KnowledgeIntelligence::GraphSnapshot.stub(:load, graph) do
        network = read(gateway, agent, "contacts.relations", "entity_id" => root_id, "depth" => 2)
        assert_equal "partial", network["status"]
        assert_equal 100, network.dig("data", "nodes").length
        assert_operator network.dig("data", "edges").length, :<=, 200
        assert_includes network["limitations"], "result_bound_reached"
        assert_equal "unavailable", read(gateway, agent, "contacts.top")["status"]
        detail = read(gateway, agent, "contacts.get", "entity_id" => root_id)
        assert_nil detail.dig("data", "item", "interaction", "score")
      end
    end
  end

  def test_generic_vault_missing_storage_and_denied_discovery_do_not_write
    with_vault do |root|
      gateway, agent = build_gateway(root, permissions: GRANTS + ["dataset:read"], clock: -> { NOW })
      index = KnowledgeExtraction::ProposalReader.new(vault_root: root)
      assert_empty index.submissions
      %i[save approve save_submission record_source atomic_write].each { |method| refute index.respond_to?(method) }
      before = Dir.glob(File.join(root, "**/*"), File::FNM_DOTMATCH)
      assert_equal "unavailable", read(gateway, agent, "contacts.list")["status"]
      assert_equal "empty", read(gateway, agent, "captures.list")["status"]
      history = read(gateway, agent, "activity.list")
      assert_includes history["limitations"], "dataset_activity_not_available"
      assert_equal before, Dir.glob(File.join(root, "**/*"), File::FNM_DOTMATCH)
      denied = AgentPlatform::AgentIdentity.new(id: "denied", permissions: ["graph:read"])
      refute gateway.discover(agent: denied).any? { |item| item["capability_id"] == "kg.activity.list" }
    end
  end
end
