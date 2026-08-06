# frozen_string_literal: true

require_relative "../test_helper"

class KnowledgeCaptureRoutingTest < Minitest::Test
  def test_multilingual_explicit_capture_kinds
    examples = {
      "Запомни мысль: автоматизировать клиентские отчёты." => "thought",
      "Есть идея: сделать локальный индекс." => "idea",
      "Я понял что регулярный обзор снижает ошибки." => "lesson",
      "Интересная гипотеза: задержка связана с очередью." => "hypothesis",
      "Почему стратегия перестала работать?" => "question",
      "I noticed that weekly reviews reveal repeated ideas." => "observation",
      "Έχω μια ιδέα: αυτοματοποίηση αναφορών." => "idea"
    }
    resolver = KnowledgeGraph::ChatIntentResolver.new
    examples.each do |text, kind|
      decision = resolver.resolve(text)
      assert_equal "capture", decision.route, text
      assert_equal "knowledge.capture", decision.intent, text
      assert_equal kind, decision.slots.fetch("kind"), text
    end
  end

  def test_graph_dataset_search_and_unknown_messages_do_not_become_captures
    resolver = KnowledgeGraph::ChatIntentResolver.new

    graph = resolver.resolve("Ivan Petrov works at ExampleCo.")
    assert_equal "observe", graph.route
    refute_equal "knowledge.capture", graph.intent

    dataset = resolver.resolve(
      "Blood pressure was 128 over 81.",
      "captured_at" => "2026-08-06T10:00:00Z", "source_type" => "chat"
    )
    assert_equal "dataset", dataset.route
    refute_equal "knowledge.capture", dataset.intent

    search = resolver.resolve("What ideas do I have about AI?")
    assert_equal "search", search.route
    assert_equal "graph.search", search.intent

    %w[Сделай\ это Нужно\ разобраться].each do |text|
      decision = resolver.resolve(text)
      assert_equal "clarification", decision.route, text
      assert_equal "chat.clarification", decision.intent, text
    end
  end

  def test_explicit_capture_wrapper_prevents_inner_crm_words_from_becoming_dataset_rows
    decision = KnowledgeGraph::ChatIntentResolver.new.resolve(
      "I have an idea: automate client reports.",
      "captured_at" => "2026-08-06T10:00:00Z", "source_type" => "chat"
    )
    assert_equal "capture", decision.route
    assert_equal "idea", decision.slots.fetch("kind")
  end
end
