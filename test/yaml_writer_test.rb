# frozen_string_literal: true

require_relative "test_helper"

class YamlWriterTest < Minitest::Test
  def test_emits_canonical_order_and_quotes_wiki_links
    writer = KnowledgeGraph::YamlWriter.new
    rendered = writer.render(
      { "name" => "Ada", "type" => "person", "id" => "person_1", "city" => "[[Places/Cities/London|London]]" },
      body: "# Ada\n\nHuman notes\n"
    )

    assert_operator rendered.index("id:"), :<, rendered.index("type:")
    assert_operator rendered.index("type:"), :<, rendered.index("name:")
    assert_includes rendered, 'city: "[[Places/Cities/London|London]]"'
    assert rendered.end_with?("# Ada\n\nHuman notes\n")
  end

  def test_round_trips_unknown_flat_keys_and_body
    writer = KnowledgeGraph::YamlWriter.new
    original = { "id" => "person_1", "custom_scalar" => "kept", "custom_list" => ["one", "two"] }
    rendered = writer.render(original, body: "Human-owned body\n")
    parsed = KnowledgeGraph::MarkdownDocument.parse(rendered)

    assert_equal original, parsed.frontmatter
    assert_equal "Human-owned body\n", parsed.body
  end

  def test_rejects_nested_yaml
    assert_raises(KnowledgeGraph::ValidationError) do
      KnowledgeGraph::YamlWriter.new.render("nested" => { "forbidden" => true })
    end
  end
end
