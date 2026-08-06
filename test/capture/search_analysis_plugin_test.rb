# frozen_string_literal: true

require_relative "../test_helper"

class KnowledgeCaptureSearchAnalysisPluginTest < Minitest::Test
  FIXED_TIME = Time.utc(2026, 8, 6, 12, 0, 0)
  RUN_ID = "run_01KZAF0000QG5K6E7P8R9S0T1V"

  def test_capture_search_and_cross_knowledge_analysis_use_capture_evidence
    with_vault do |root|
      engine = KnowledgeGraph::Engine.new(vault_root: root, run_id: RUN_ID, clock: -> { FIXED_TIME })
      create_capture(engine, "capture_01KZAF0000QG5K6E7P8R9S0T2V", "idea", "AI reports", "Automate AI client reports.")
      create_capture(engine, "capture_01KZAF0000QG5K6E7P8R9S0T3V", "idea", "AI summaries", "Automate AI weekly summaries.")
      create_capture(engine, "capture_01KZAF0000QG5K6E7P8R9S0T4V", "lesson", "Trading review", "Review trading risk before entry.")
      engine.execute(KnowledgeGraph::CreateCapture.new(
        capture_id: "capture_01KZAF0000QG5K6E7P8R9S0T6V", kind: "idea", title: "Restricted AI idea",
        body: "Restricted AI content.", captured_at: FIXED_TIME.iso8601, language: "en",
        source: "test", sensitivity: "restricted"
      ))

      search = KnowledgeCapture::Search.new(vault_root: root, clock: -> { FIXED_TIME }).query(
        "What ideas do I have about AI?", include_ids: true
      )
      assert_equal 2, search.fetch("count")
      assert search.fetch("matches").all? { |item| item.fetch("kind") == "idea" }
      assert search.fetch("matches").all? { |item| item.fetch("capture_id").start_with?("capture_") }

      analysis = KnowledgeAnalysis::Engine.new(
        vault_root: root, clock: -> { FIXED_TIME }
      ).analyze("What themes appear most often in my captured ideas?").fetch("analysis")
      assert_includes analysis.fetch("analysis_modules").map { |item| item.fetch("name") }, "capture"
      assert_equal 2, analysis.fetch("capture_evidence").length
      assert_operator analysis.dig("capture_summary", "themes").length, :>, 0
      assert_includes analysis.fetch("subsystems"), "knowledge_capture"
    end
  end

  def test_trusted_plugins_contribute_all_capture_extension_shapes
    plugin_class = Class.new do
      def name
        "synthetic-capture-plugin"
      end

      def enrich_capture(attributes)
        attributes.merge("importance" => "high")
      end

      def extract_capture_topics(_text)
        ["synthetic-topic"]
      end

      def capture_link_candidates(_text, _context)
        []
      end

      def build_capture_promotion(_capture, _kind, _options)
        nil
      end

      def capture_recommendations(_capture)
        ["Review the synthetic Capture."]
      end
    end
    registry = KnowledgeCapture::PluginRegistry.new
    plugin = plugin_class.new
    registry.register(plugin)
    assert_equal [plugin], registry.all
    assert_equal "high", registry.enrich("importance" => "normal").fetch("importance")
    assert_equal ["synthetic-topic"], registry.topics("anything")
    assert_raises(KnowledgeCapture::PluginError) do
      registry.register(Class.new { def name; "invalid"; end }.new)
    end
  end

  def test_capture_cli_hides_internal_ids_unless_requested
    with_vault do |root|
      engine = KnowledgeGraph::Engine.new(vault_root: root, run_id: RUN_ID, clock: -> { FIXED_TIME })
      create_capture(engine, "capture_01KZAF0000QG5K6E7P8R9S0T5V", "note", "Hidden identifier", "Body.")

      out = StringIO.new
      status = KnowledgeGraph::CLI.run(["--vault", root, "inbox"], out: out, err: StringIO.new)
      assert_equal 0, status
      refute_includes out.string, "capture_01KZAF"

      out = StringIO.new
      status = KnowledgeGraph::CLI.run(
        ["--vault", root, "capture", "show", "Hidden identifier", "--json"],
        out: out, err: StringIO.new
      )
      assert_equal 0, status
      public_capture = JSON.parse(out.string).fetch("capture")
      refute public_capture.key?("capture_id")
      refute public_capture.key?("evidence")

      out = StringIO.new
      status = KnowledgeGraph::CLI.run(
        ["--vault", root, "capture", "show", "Hidden identifier", "--json"],
        out: out, err: StringIO.new
      )
      assert_equal 0, status
      public_capture = JSON.parse(out.string).fetch("capture")
      refute public_capture.key?("capture_id")
      refute public_capture.key?("evidence")

      out = StringIO.new
      status = KnowledgeGraph::CLI.run(["--vault", root, "inbox", "--ids"], out: out, err: StringIO.new)
      assert_equal 0, status
      assert_includes out.string, "capture_01KZAF"
    end
  end

  private

  def create_capture(engine, id, kind, title, body)
    engine.execute(KnowledgeGraph::CreateCapture.new(
      capture_id: id, kind: kind, title: title, body: body,
      captured_at: FIXED_TIME.iso8601, language: "en", source: "test"
    ))
  end
end
