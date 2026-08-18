# frozen_string_literal: true

require "set"

module KnowledgeCapture
  class AnalysisPlugin < KnowledgeAnalysis::Plugins::Base
    NAME = "capture"
    QUESTION = /(?:\b(?:capture|captures|captured|saved|bookmark|bookmarks|website|websites|site|sites|article|articles|resource|resources|domain|domains|idea|ideas|thought|thoughts|note|notes|question|questions|lesson|lessons|theme|themes|repeat|repeated|concern|concerns|frequently)\b|(?:сохраня|заклад|ссыл|сайт|стат|ресурс|домен|иде[яи]|мысл|замет|вопрос|урок|тем|повтор|беспоко)|(?:αποθηκεύ|σελιδοδείκ|σύνδεσ|ιστότοπ|άρθρ|πόρ|ιδέ|σκέψ|σημείωσ|ερώτησ|μάθημα|θέμα|επαναλ))/i.freeze
    STOPWORDS = Set.new(%w[
      about and appear are did do for have i in is most my of often the what which with
      мне мои про что какие часто есть это как почему
      και για μου ποια τι είναι συχνά
    ]).freeze

    def supports?(question, context)
      !context.captures.empty? && QUESTION.match?(question)
    end

    def contributions
      super.merge(
        "analyzers" => ["capture_themes", "capture_repetition", "capture_concerns"],
        "capture_interpreters" => ["kind", "topics", "tags", "body"],
        "recommendation_generators" => ["capture_review"]
      )
    end

    def analyze(context)
      captures = relevant(context)
      frequencies = term_frequencies(captures)
      themes = frequencies.first(10).map do |term, count|
        { "theme" => term, "count" => count }
      end
      repeated = captures.group_by { |capture| normalize(capture.body) }.values
                         .select { |group| group.length > 1 }
      kind_counts = captures.each_with_object(Hash.new(0)) { |capture, counts| counts[capture.kind] += 1 }
      evidence = captures.first(100).map do |capture|
        {
          "capture_id" => capture.id, "kind" => capture.kind, "title" => capture.title,
          "captured_at" => capture.captured_at.iso8601, "status" => capture.status,
          "topics" => capture.topics, "tags" => capture.tags,
          "domain" => capture.domain, "resource_type" => capture.resource_type,
          "author_name" => capture.author_name, "collections" => capture.collections,
          "evidence_ids" => capture.evidence
        }.reject { |_key, value| value.nil? || (value.respond_to?(:empty?) && value.empty?) }
      end
      factors = themes.first(5).map do |theme|
        context.factor(
          label: "Capture theme: #{theme.fetch('theme')}",
          association: "#{theme.fetch('theme')} appears in #{theme.fetch('count')} matching Capture record(s).",
          confidence: [theme.fetch("count").to_f / [captures.length, 1].max, 1.0].min,
          datasets: [], evidence: {
            "capture_ids" => captures.select do |capture|
              tokens(capture).include?(theme.fetch("theme"))
            end.map(&:id)
          }, limitations: ["Term frequency reflects recorded wording, not importance or causality."]
        )
      end
      recommendations = captures.flat_map { |capture| KnowledgeCapture.registry.recommendations(capture) }
                              .uniq.first(20).map do |text|
        recommendation(text, confidence: 0.7, evidence: evidence.first(5).map { |item| item.fetch("capture_id") })
      end
      summary = if captures.empty?
                  "No policy-visible Captures matched the analysis question."
                else
                  "Analysed #{captures.length} Capture record(s) across #{kind_counts.length} kind(s); " \
                    "#{repeated.length} exact repeated wording group(s) were found."
                end
      fragment(
        summary: summary, confidence: captures.empty? ? 0.0 : 0.9,
        factors: factors, capture_evidence: evidence,
        graph_evidence: related_graph_evidence(captures),
        activity_evidence: context.relevant_activities(["capture", "inbox"], limit: 50),
        recommendations: recommendations,
        limitations: [
          "Capture analysis uses only locally recorded, policy-visible content.",
          "Repeated language and temporal co-occurrence do not establish equivalence, priority, or causality."
        ]
      ).merge(
        "capture_summary" => {
          "kinds" => kind_counts.sort.to_h, "themes" => themes,
          "bookmark_domains" => frequency(captures.map(&:domain)),
          "bookmark_resource_types" => frequency(captures.map(&:resource_type)),
          "bookmark_topics" => frequency(captures.flat_map(&:topics)),
          "exact_repeated_groups" => repeated.map { |group| group.map(&:id).sort }
        }
      )
    end

    private

    def relevant(context)
      kind = Search::KIND_TERMS.keys.find do |candidate|
        Search::KIND_TERMS.fetch(candidate).any? do |term|
          normalize(context.question).include?(normalize(term))
        end
      end
      selected = context.captures.reject { |capture| capture.status == "deleted" }
      selected = selected.select { |capture| capture.kind == kind } if kind
      selected.sort_by { |capture| [capture.captured_at, capture.id] }.reverse
    end

    def term_frequencies(captures)
      counts = Hash.new(0)
      captures.each do |capture|
        tokens(capture).uniq.each { |term| counts[term] += 1 }
      end
      counts.sort_by { |term, count| [-count, term] }
    end

    def tokens(capture)
      normalize([
        capture.title, capture.body, capture.topics, capture.tags, capture.domain,
        capture.resource_type, capture.author_name, capture.description,
        capture.content_excerpt, capture.user_note, capture.collections
      ].flatten.compact.join(" "))
        .scan(/[\p{L}\p{N}][\p{L}\p{N}_-]{2,}/u)
        .reject { |term| STOPWORDS.include?(term) || term.start_with?("capture") }
    end

    def related_graph_evidence(captures)
      ids = captures.flat_map do |capture|
        capture.related_entities + capture.related_projects + capture.related_contacts
      end.uniq.sort
      ids.map { |id| { "record_id" => id, "fields" => ["capture_link"] } }
    end

    def frequency(values)
      values.compact.map(&:to_s).reject(&:empty?).each_with_object(Hash.new(0)) do |value, counts|
        counts[value] += 1
      end.sort_by { |value, count| [-count, value] }.to_h
    end

    def normalize(value)
      value.to_s.encode(Encoding::UTF_8).unicode_normalize(:nfc).downcase.tr("ё", "е").strip
    end
  end
end
