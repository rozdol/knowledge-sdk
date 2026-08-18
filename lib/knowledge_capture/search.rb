# frozen_string_literal: true

require "set"

module KnowledgeCapture
  class Search
    KIND_TERMS = {
      "thought" => %w[thought thoughts мысль мысли σκέψη σκέψεις],
      "idea" => %w[idea ideas идея идеи ιδέα ιδέες],
      "note" => %w[note notes заметка заметки запись записи σημείωση σημειώσεις],
      "question" => %w[question questions вопрос вопросы ερώτηση ερωτήσεις],
      "lesson" => %w[lesson lessons урок уроки μάθημα μαθήματα],
      "decision" => %w[decision decisions решение решения απόφαση αποφάσεις],
      "observation" => %w[observation observations наблюдение наблюдения παρατήρηση παρατηρήσεις],
      "bookmark" => %w[
        bookmark bookmarks link links website websites site sites article articles resource resources
        закладка закладки ссылка ссылки сайт сайты статья статьи ресурс ресурсы
        σελιδοδείκτης σελιδοδείκτες σύνδεσμος σύνδεσμοι ιστότοπος ιστότοποι άρθρο άρθρα
      ],
      "reference" => %w[reference references справка источник αναφορά αναφορές],
      "quote" => %w[quote quotes цитата цитаты απόσπασμα],
      "hypothesis" => %w[hypothesis hypotheses гипотеза гипотезы υπόθεση υποθέσεις]
    }.freeze
    STOPWORDS = Set.new(%w[
      a an and are about do did does for have has i in is me my of on or still the to was what which
      with write wrote recorded recently last week show find tell capture captured unanswered
      какие что у меня есть про об обо по я записал записала писал писала на за последние недавно
      ποια τι έχω για με μου έγραψα τελευταία πρόσφατα
    ]).freeze

    def initialize(vault_root:, clock: nil, registry: KnowledgeCapture.registry)
      @store = Store.new(vault_root: vault_root)
      @clock = clock || -> { Time.now }
      @registry = registry
    end

    def query(text, limit: 25, include_ids: false, include_restricted: false, status: nil, kind: nil)
      source = text.to_s.strip
      raise InvalidCapture, "capture search query is required" if source.empty?
      selected_kind = kind.to_s.empty? ? inferred_kind(source) : kind.to_s
      selected_status = status.to_s.empty? ? inferred_status(source) : status.to_s
      from = inferred_from(source)
      terms = query_terms(source)
      matches = @store.all.each_with_object([]) do |capture, result|
        next if capture.status == "deleted"
        next if capture.sensitivity == "restricted" && !include_restricted
        next if selected_kind && capture.kind != selected_kind
        if selected_status == "unanswered"
          next unless capture.kind == "question" && !%w[promoted archived deleted].include?(capture.status)
        elsif selected_status && capture.status != selected_status
          next
        end
        next if from && capture.captured_at < from

        score = relevance(capture, terms)
        next if !terms.empty? && score.zero?

        result << [capture, score]
      end
      matches.sort_by! { |capture, score| [-score, -capture.captured_at.to_f, capture.id] }
      public_matches = matches.first(Integer(limit)).map do |capture, score|
        capture.public_h(include_id: include_ids).merge("relevance" => score.round(4))
      end
      {
        "query" => source, "intent" => "knowledge.capture.search",
        "filters" => {
          "kind" => selected_kind, "status" => selected_status,
          "from" => from && from.iso8601
        }.reject { |_key, value| value.nil? },
        "matches" => public_matches, "count" => public_matches.length,
        "explanation" => "Matched Capture kind, lifecycle, time, title, user annotation, topics, tags, bookmark domain, resource type, author, description, excerpt, and Markdown body with deterministic Unicode token scoring."
      }
    end

    private

    def inferred_kind(text)
      tokens = tokenize(text)
      KIND_TERMS.each do |kind, names|
        return kind unless (tokens & names.map { |name| normalize(name) }).empty?
      end
      nil
    end

    def inferred_status(text)
      normalized = normalize(text)
      return "inbox" if normalized.match?(/\b(?:inbox|unreviewed)\b|неразобран|входящ/)
      return "archived" if normalized.match?(/\barchived\b|архив/)
      return "promoted" if normalized.match?(/\bpromoted\b|преобразован/)
      return "reviewed" if normalized.match?(/\breviewed\b|просмотрен/)
      return "unanswered" if normalized.match?(/\bunanswered\b|без\s+ответ|неотвечен/)

      nil
    end

    def inferred_from(text)
      normalized = normalize(text)
      return @clock.call - (7 * 86_400) if normalized.match?(/\blast week\b|за последн(?:юю|ие) недел|την περασμένη εβδομάδα/)
      return @clock.call - (30 * 86_400) if normalized.match?(/\b(?:recent|recently|latest)\b|недавн|последн|πρόσφατ|τελευτα/)

      nil
    end

    def query_terms(text)
      kind_words = KIND_TERMS.values.flatten.map { |word| normalize(word) }.to_set
      tokenize(text).reject { |word| STOPWORDS.include?(word) || kind_words.include?(word) }.uniq
    end

    def relevance(capture, terms)
      return 1.0 if terms.empty?

      title = tokenize(capture.title)
      topics = capture.topics.flat_map { |value| tokenize(value) }
      tags = capture.tags.flat_map { |value| tokenize(value) }
      body = tokenize(capture.body)
      bookmark = tokenize([
        capture.domain, capture.resource_type, capture.author_name, capture.description,
        capture.content_excerpt, capture.user_note, capture.collections
      ].flatten.compact.join(" "))
      terms.sum do |term|
        score = 0.0
        score += 4.0 if title.include?(term)
        score += 3.0 if topics.include?(term)
        score += 2.0 if tags.include?(term)
        score += 3.0 if bookmark.include?(term)
        score += 1.0 if body.include?(term)
        score
      end
    end

    def tokenize(value)
      normalize(value).scan(/[\p{L}\p{N}][\p{L}\p{N}_-]*/u)
    end

    def normalize(value)
      value.to_s.encode(Encoding::UTF_8).unicode_normalize(:nfc).downcase.tr("ё", "е")
    end
  end
end
