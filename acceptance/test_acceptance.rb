#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "lib/acceptance_support"
require_relative "lib/dataview_runner"

class AcceptanceSupportTest < Minitest::Test
  FakeNote = Struct.new(:relative, :data)

  def test_deterministic_ulids_are_stable_unique_and_valid
    first = PKGAcceptance.deterministic_ulid("seed", "person", 1)
    assert_equal first, PKGAcceptance.deterministic_ulid("seed", "person", 1)
    refute_equal first, PKGAcceptance.deterministic_ulid("seed", "person", 2)
    assert_match(/\A[0-9A-HJKMNP-TV-Z]{26}\z/, first)
  end

  def test_dataview_expression_handles_links_dates_and_boolean_groups
    note = FakeNote.new("Relationships/lives_in/x.md", {
      "type" => "relationship", "relationship_status" => "asserted",
      "object" => "[[Places/Cities/London|London]]", "valid_to" => nil
    })
    expression = PKGAcceptance::DataviewExpression.new(<<~QUERY.gsub("\n", " "))
      type = "relationship" AND relationship_status = "asserted"
      AND object = [[Places/Cities/London]]
      AND (!valid_to OR date(valid_to) >= date(today))
    QUERY
    assert expression.call(note)
  end

  def test_note_io_round_trip_preserves_flat_wikilinks
    Dir.mktmpdir do |root|
      path = File.join(root, "note.md")
      data = { "id" => "x", "links" => ["[[People/Self|Self]]"] }
      PKGAcceptance::NoteIO.write(path, data, "# Body\n")
      loaded, body = PKGAcceptance::NoteIO.read(path)
      assert_equal data, loaded
      assert_equal "# Body\n", body
    end
  end


  def test_dataview_expression_compares_iso_timestamp_to_today
    note = FakeNote.new("Interactions/Events/x.md", { "starts_at" => "2026-08-01T12:00:00+03:00" })
    assert PKGAcceptance::DataviewExpression.new("starts_at >= date(today)").call(note)
  end
end
