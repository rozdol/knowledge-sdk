# encoding: UTF-8
# frozen_string_literal: true

module KnowledgeCapture
  class IntentClassifierPlugin
    PREFIXES = [
      ["thought", /\A(?:remember\s+(?:this\s+)?thought|thought|запомни\s+мысль|мысль|запомни|σκέψη|θυμήσου\s+(?:αυτή\s+)?τη\s+σκέψη)\s*[:—-]?\s*/i],
      ["idea", /\A(?:i\s+have\s+an\s+idea|there(?:'s|\s+is)\s+an\s+idea|idea|есть\s+идея|идея|у\s+меня\s+идея|έχω\s+(?:μια\s+)?ιδέα|ιδέα)\s*[:—-]?\s*/i],
      ["note", /\A(?:take\s+(?:a\s+)?note|write\s+(?:this\s+)?down|note|запиши|записать|заметка|σημείωσε|σημείωση)\s*[:—-]?\s*/i],
      ["hypothesis", /\A(?:interesting\s+hypothesis|hypothesis|интересная\s+гипотеза|гипотеза|ενδιαφέρουσα\s+υπόθεση|υπόθεση)\s*[:—-]?\s*/i],
      ["lesson", /\A(?:i\s+(?:learned|realized|understood)(?:\s+that)?|lesson|я\s+понял(?:а)?(?:\s+что)?|урок|κατάλαβα(?:\s+ότι)?|μάθημα)\s*[:—-]?\s*/i],
      ["decision", /\A(?:i\s+(?:have\s+)?decided(?:\s+that|\s+to)?|decision|я\s+решил(?:а)?|решение|αποφάσισα|απόφαση)\s*[:—-]?\s*/i],
      ["observation", /\A(?:i\s+(?:noticed|observed)(?:\s+that)?|observation|я\s+заметил(?:а)?(?:\s+что)?|наблюдение|παρατήρησα(?:\s+ότι)?|παρατήρηση)\s*[:—-]?\s*/i],
      ["bookmark", /\A(?:bookmark|save\s+this\s+link|закладка|сохрани\s+ссылку|σελιδοδείκτης)\s*[:—-]?\s*/i],
      ["reference", /\A(?:reference|keep\s+this\s+reference|справка|сохрани\s+источник|αναφορά)\s*[:—-]?\s*/i],
      ["quote", /\A(?:quote|цитата|απόσπασμα)\s*[:—-]?\s*/i],
      ["question", /\A(?:my\s+question|question\s+i\s+have|вопрос|мой\s+вопрос|ερώτησή\s+μου|ερώτηση)\s*[:—-]?\s*/i]
    ].freeze
    RUSSIAN_PERSONAL_QUESTION = /\Aпочему\s+.{6,}\?\z/i.freeze

    class << self
      def register(classifier = KnowledgeSDK.intent_classifier)
        classifier.register(name: "knowledge-capture-core", domain: "generic", route: "capture") do |text, _context|
          parsed = parse(text)
          next nil unless parsed

          {
            "intent" => "knowledge.capture", "confidence" => parsed.fetch("confidence"),
            "explanation" => "message explicitly expresses a personal #{parsed.fetch('kind')} to capture",
            "slots" => parsed
          }
        end
      end

      def parse(text)
        source = text.to_s.strip
        PREFIXES.each do |kind, pattern|
          match = pattern.match(source)
          next unless match

          body = source.sub(pattern, "").strip
          next if body.empty?

          return slots(kind, body, 0.98)
        end
        return slots("question", source, 0.97) if RUSSIAN_PERSONAL_QUESTION.match?(source)

        nil
      end

      def explicit_capture?(text)
        !parse(text).nil?
      end

      private

      def slots(kind, body, confidence)
        {
          "kind" => kind, "body" => body, "title" => title(body),
          "language" => language(body), "confidence" => confidence
        }.freeze
      end

      def title(body)
        value = body.lines.first.to_s.strip.sub(/[.!?。]+\z/, "")
        value = body.strip if value.empty?
        value.length > 100 ? "#{value[0, 97].rstrip}..." : value
      end

      def language(body)
        scripts = []
        scripts << "ru" if body.match?(/[А-Яа-яЁё]/)
        scripts << "el" if body.match?(/\p{Greek}/u)
        scripts << "en" if body.match?(/[A-Za-z]/)
        scripts.length > 1 ? "mixed" : (scripts.first || "und")
      end
    end
  end
end
