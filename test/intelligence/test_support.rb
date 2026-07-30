# frozen_string_literal: true

require_relative "../test_helper"

module IntelligenceTestSupport
  AS_OF = Date.new(2026, 7, 29)

  def rich_snapshot
    records = []
    records << snapshot_record("person_self", "person", "Synthetic Owner", "People/Synthetic Owner.md", {
      "is_self" => true, "tier" => "inner", "sensitivity" => "private", "data_origin" => "public",
      "emails" => ["owner@example.test"], "phones" => ["+15550000001"]
    })
    records << snapshot_record("person_ada", "person", "Ada Example", "People/Ada Example.md", {
      "tier" => "active", "sensitivity" => "private", "data_origin" => "given_by_subject", "aliases" => []
    })
    records << snapshot_record("person_bob", "person", "Bob Example", "People/Bob Example.md", {
      "tier" => "active", "sensitivity" => "private", "data_origin" => "given_by_subject",
      "emails" => ["bob@example.test"]
    })
    records << snapshot_record("person_cara", "person", "Cara Isolated", "People/Cara Isolated.md", {
      "tier" => "dormant", "sensitivity" => "private", "data_origin" => "third_party"
    })
    records << snapshot_record("person_leaf", "person", "Eli Bridge Leaf", "People/Eli Bridge Leaf.md", {
      "tier" => "active", "sensitivity" => "private", "data_origin" => "third_party"
    })
    records << snapshot_record("person_faye", "person", "Faye Opportunity", "People/Faye Opportunity.md", {
      "tier" => "active", "sensitivity" => "private", "data_origin" => "given_by_subject"
    })
    records << snapshot_record("person_dup_a", "person", "Dana Duplicate", "People/Dana Duplicate A.md", {
      "tier" => "active", "sensitivity" => "private", "data_origin" => "third_party"
    })
    records << snapshot_record("person_dup_b", "person", "Dana Duplicate", "People/Dana Duplicate B.md", {
      "tier" => "active", "sensitivity" => "private", "data_origin" => "third_party"
    })
    records << snapshot_record("interest_ai", "interest", "Synthetic AI", "Concepts/Interests/Synthetic AI.md", {})
    records << snapshot_record("org_fund", "organization", "Synthetic Ventures", "Organizations/Synthetic Ventures.md", {
      "org_kind" => "fund", "domains" => ["example.test"]
    })
    records << snapshot_record("project_apollo", "project", "Project Apollo Test", "Work/Projects/Project Apollo Test.md", {
      "project_status" => "active", "started_on" => "2025-01-01", "technologies" => [], "topics" => []
    })
    records << snapshot_record("city_london", "city", "Synthetic London", "Places/Cities/Synthetic London.md", {})
    records << snapshot_record("event_summit", "event", "Synthetic AI Summit", "Interactions/Events/Synthetic AI Summit.md", {
      "starts_at" => "2026-09-15T09:00:00Z", "location" => "Synthetic London"
    })

    records << relationship("rel_self_ada", "person_self", "knows", "person_ada", "close")
    records << relationship("rel_self_bob", "person_self", "knows", "person_bob", "regular")
    records << relationship("rel_self_faye", "person_self", "knows", "person_faye", "regular")
    records << relationship("rel_ada_ai", "person_ada", "interested_in", "interest_ai")
    records << relationship("rel_bob_ai", "person_bob", "interested_in", "interest_ai")
    records << relationship("rel_faye_ai", "person_faye", "interested_in", "interest_ai")
    records << relationship("rel_ada_investor", "person_ada", "invested_in", "org_fund")
    records << relationship("rel_ada_leaf", "person_ada", "knows", "person_leaf", "acquaintance")
    records << relationship("rel_like", "person_self", "likes", "interest_ai")
    records << relationship("rel_dislike", "person_self", "dislikes", "interest_ai")

    records << interaction(
      "interaction_old", "Old synthetic meeting", "2025-12-31T10:00:00Z", %w[person_self person_ada]
    )
    records << interaction(
      "interaction_recent", "Recent synthetic call", "2026-07-20T10:00:00Z", %w[person_self person_bob]
    )
    records << introduction("intro_one", "person_ada", "person_self", "person_bob", "2026-01-15")
    records << introduction("intro_two", "person_ada", "person_self", "person_cara", "2026-02-15")

    records << snapshot_record("commitment_overdue", "commitment", "Send synthetic brief", "Commitments/Promises/Send synthetic brief.md", {
      "commitment_status" => "open", "commitment_kind" => "promise", "action" => "Send synthetic brief",
      "promisor" => link("People/Synthetic Owner", "Synthetic Owner"),
      "promise_to" => link("People/Ada Example", "Ada Example"), "made_on" => "2026-01-01",
      "due_on" => "2026-02-01", "sensitivity" => "private", "data_origin" => "given_by_subject"
    })
    records << snapshot_record("followup_overdue", "follow-up", "Synthetic follow-up", "Commitments/Follow-ups/Synthetic follow-up.md", {
      "owner" => link("People/Synthetic Owner", "Synthetic Owner"), "action" => "Check synthetic status",
      "followup_status" => "open", "with" => [link("People/Ada Example", "Ada Example")],
      "due_on" => "2026-06-01", "priority" => "high", "sensitivity" => "private", "data_origin" => "given_by_subject"
    })
    KnowledgeIntelligence::GraphSnapshot.new(records)
  end

  def snapshot_record(id, type, name, path, attributes)
    base = {
      "id" => id, "type" => type, "name" => name, "aliases" => [],
      "record_status" => "active", "created_at" => "2025-01-01T00:00:00Z",
      "updated_at" => "2025-01-01T00:00:00Z", "created_by" => "human", "updated_by" => "human"
    }
    KnowledgeIntelligence::RecordSnapshot.new(
      id: id, type: type, name: name, path: path, data: base.merge(attributes)
    )
  end

  def relationship(id, source, predicate, target, closeness = nil)
    attributes = {
      "subject_id" => source, "predicate" => predicate, "object_id" => target,
      "relationship_status" => "asserted", "confidence" => "confirmed",
      "asserted_by" => "human", "asserted_at" => "2025-01-01T00:00:00Z",
      "sensitivity" => "private", "data_origin" => "given_by_subject"
    }
    attributes["closeness"] = closeness if closeness
    snapshot_record(id, "relationship", nil, "Relationships/#{predicate}/#{id}.md", attributes)
  end

  def interaction(id, name, starts_at, participant_ids)
    paths = {
      "person_self" => ["People/Synthetic Owner", "Synthetic Owner"],
      "person_ada" => ["People/Ada Example", "Ada Example"],
      "person_bob" => ["People/Bob Example", "Bob Example"],
      "person_cara" => ["People/Cara Isolated", "Cara Isolated"]
    }
    snapshot_record(id, "interaction", name, "Interactions/Meetings/#{name}.md", {
      "starts_at" => starts_at,
      "participants" => participant_ids.map { |participant| link(*paths.fetch(participant)) },
      "interaction_kind" => "meeting", "contact_weight" => "substantive",
      "sensitivity" => "private", "data_origin" => "given_by_subject"
    })
  end

  def introduction(id, introducer, first, second, occurred_on)
    pair = [first, second].sort
    snapshot_record(id, "introduction", nil, "Interactions/Introductions/#{id}.md", {
      "introducer_id" => introducer, "person_a_id" => pair[0], "person_b_id" => pair[1],
      "assertion_status" => "asserted", "confidence" => "confirmed", "occurred_on" => occurred_on
    })
  end

  def link(path, label)
    "[[#{path}|#{label}]]"
  end

  def feature_engine(snapshot = rich_snapshot)
    KnowledgeIntelligence::FeatureEngine.new(
      snapshot: snapshot, registry: KnowledgeIntelligence::DefaultFeatures.registry, as_of: AS_OF
    )
  end
end

class Minitest::Test
  include IntelligenceTestSupport
end
