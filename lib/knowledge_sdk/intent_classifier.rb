# encoding: UTF-8
# frozen_string_literal: true

module KnowledgeSDK
  class ClassifierTextNormalizer
    NormalizedText = Struct.new(:original, :matching, keyword_init: true)

    def normalize(value)
      original = value.to_s.encode(Encoding::UTF_8).unicode_normalize(:nfc)
                      .gsub("\r\n", "\n").gsub("\r", "\n").delete("\u0000").strip
      raise ArgumentError, "classification text is empty" if original.empty?

      matching = original.downcase.tr("ё", "е")
      NormalizedText.new(original: original.freeze, matching: matching.freeze).freeze
    rescue Encoding::InvalidByteSequenceError, Encoding::UndefinedConversionError
      raise ArgumentError, "classification text must be valid UTF-8"
    end
  end

  class DomainClassification
    attr_reader :domain, :confidence, :explanation

    def initialize(domain:, confidence:, explanation:)
      @domain = domain.to_s.strip.freeze
      @confidence = Float(confidence)
      @explanation = explanation.to_s.strip.freeze
      raise ArgumentError, "domain is required" if @domain.empty?
      unless @confidence.between?(0.0, 1.0)
        raise ArgumentError, "domain confidence must be between 0 and 1"
      end
      raise ArgumentError, "domain explanation is required" if @explanation.empty?

      freeze
    end
  end

  class SemanticDomainClassifier
    DOMAINS = %w[health finance crm trading knowledge generic].freeze
    DOMAIN_RULES = {
      "health" => [
        /(?:medicat|medicine|dosage|dose|tablet|\b(?:take|taking)\b.*\b(?:every\s+(?:morning|afternoon|evening|night|day)|once\s+daily|twice\s+daily)|blood\s+pressure|heart\s+rate|pulse|weight|waist|body[ -]fat|body\s+temperature|oxygen\s+saturation|laboratory|\blab\b|cholesterol|glucose|insulin|hemoglobin|haemoglobin|\bldl\b|\bhdl\b|nutrition|protein|sleep\s+duration)/i,
        /(?:лекарств|препарат|принима|при[её]м|пью|выпива|принял|приняла|таблет|капсул|доз|давлен|пульс|частот[[:alpha:]]*\s+сердц|\bвес\b|тали|температур[[:alpha:]]*\s+тел|сатурац|анализ|лаборатор|холестерин|глюкоз|гемоглобин|лпнп|лпвп)/i,
        /(?:φάρμακ|παίρνω|λαμβάνω|δόση|χάπι|πίεσ|σφυγμ|καρδιακ[[:alpha:]]*\s+ρυθμ|βάρος|μέση|θερμοκρασ[[:alpha:]]*\s+σώματος|κορεσμ[[:alpha:]]*\s+οξυγόν|εξέτασ|εργαστηριακ|χοληστερ|γλυκόζ|αιμοσφαιρ|διατροφ|πρωτεΐν)/i
      ],
      "finance" => [
        /(?:expense|spent|paid|income|invoice|budget|subscription|currency|amount|revenue|cash\s+flow|[$€£₽]|\b(?:usd|eur|gbp)\b)/i,
        /(?:расход|потрат|заплат|доход|сч[её]т|бюджет|подписк|валют|сумм)/i,
        /(?:έξοδ|δαπάν|πλήρωσ|εισόδημα|τιμολόγ|προϋπολογ|συνδρομ|νόμισμα|ποσό)/i
      ],
      "crm" => [
        /(?:customer|client|contact|lead|prospect|account|works?\s+at|employed\s+by|meeting\s+with|follow[ -]?up)/i,
        /(?:клиент|контакт|лид|работает\s+в|встреча\s+с|связаться\s+с)/i,
        /(?:πελάτ|επαφή|υποψήφι|εργάζεται\s+(?:στη|στο|σε)|συνάντηση\s+με)/i
      ],
      "trading" => [
        /(?:trade|trading|portfolio|broker|ticker|stock|share\s+price|market\s+order|limit\s+order|stop[ -]?loss|position|option|futures|forex|crypto)/i,
        /(?:трейд|торгов|портфел|брокер|тикер|акци|бирж|стоп[ -]?лосс|позици|опцион|фьючерс)/i,
        /(?:συναλλαγ|χαρτοφυλάκ|χρηματιστ|μετοχ|εντολή\s+αγοράς|θέση|δικαίωμα\s+προαίρεσης|κρυπτο)/i
      ],
      "knowledge" => [
        /(?:what\s+do\s+(?:you|we)\s+know|what\s+changed|\bwhy\b|correlat|compare|knowledge|note|document|proposal|create\s+(?:a\s+)?plan|search|find|show\s+me|tell\s+me)/i,
        /(?:что\s+(?:ты|мы)\s+зна|что\s+изменилось|почему|сравни|корреляц|знан|заметк|документ|предложени|созда[[:alpha:]]*\s+план|найди|покажи)/i,
        /(?:τι\s+γνωρίζ|τι\s+άλλαξε|γιατί|σύγκριν|συσχέτισ|γνώσ|σημείωσ|έγγραφ|πρότασ|δημιούργησ[[:alpha:]]*\s+σχέδιο|βρες|δείξε)/i
      ]
    }.freeze
    DOMAIN_CONFIDENCE = {
      "health" => 0.96, "finance" => 0.94, "crm" => 0.92,
      "trading" => 0.97, "knowledge" => 0.75
    }.freeze

    def candidates(text, context = {})
      source = text.to_s.strip
      raise ArgumentError, "classification text is empty" if source.empty?
      raise ArgumentError, "classification context must be an object" unless context.is_a?(Hash)

      matches = DOMAIN_RULES.each_with_object([]) do |(domain, patterns), result|
        next unless patterns.any? { |pattern| pattern.match?(source) }

        result << DomainClassification.new(
          domain: domain, confidence: DOMAIN_CONFIDENCE.fetch(domain),
          explanation: "detected #{domain} vocabulary and concepts"
        )
      end
      return matches.freeze unless matches.empty?

      [DomainClassification.new(
        domain: "generic", confidence: 0.0,
        explanation: "no specialized semantic domain was detected"
      )].freeze
    end

    def classify(text, context = {})
      candidates(text, context).max_by(&:confidence)
    end
  end

  class IntentClassification
    attr_reader :intent, :confidence, :route, :domain, :explanation, :slots

    def initialize(intent:, confidence:, route:, explanation: nil, reason: nil,
                   domain: "generic", slots: {})
      @intent = required(intent, "intent")
      @route = required(route, "route")
      @domain = required(domain, "domain")
      @explanation = required(explanation || reason, "explanation")
      @confidence = Float(confidence)
      unless @confidence.between?(0.0, 1.0)
        raise ArgumentError, "classification confidence must be between 0 and 1"
      end
      raise ArgumentError, "classification slots must be an object" unless slots.is_a?(Hash)

      @slots = immutable(slots)
      freeze
    rescue ArgumentError, TypeError => error
      raise ArgumentError, error.message
    end

    # Compatibility for existing renderers and callers. New plugins return
    # `explanation`, which is the public classifier result field.
    def reason
      explanation
    end

    def to_h
      {
        "intent" => intent, "confidence" => confidence, "route" => route,
        "domain" => domain, "explanation" => explanation, "slots" => slots
      }
    end

    private

    def required(value, field)
      string = value.to_s.strip
      raise ArgumentError, "classification #{field} is required" if string.empty?

      string.freeze
    end

    def immutable(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, item), result|
          result[key.to_s.freeze] = immutable(item)
        end.freeze
      when Array then value.map { |item| immutable(item) }.freeze
      when String then value.dup.freeze
      else value.frozen? ? value : value.dup.freeze
      end
    rescue TypeError
      value.freeze
    end
  end

  class IntentClassifier
    DOMAINS = SemanticDomainClassifier::DOMAINS
    ROUTES = %w[dataset analyze observe search plan proposal].freeze
    Entry = Struct.new(:name, :domain, :route, :matcher, :fallback, keyword_init: true)

    attr_reader :domain_classifier, :text_normalizer

    def initialize(domain_classifier: SemanticDomainClassifier.new,
                   text_normalizer: ClassifierTextNormalizer.new)
      unless domain_classifier.respond_to?(:classify)
        raise ArgumentError, "domain classifier must respond to classify"
      end
      unless text_normalizer.respond_to?(:normalize)
        raise ArgumentError, "text normalizer must respond to normalize"
      end

      @domain_classifier = domain_classifier
      @text_normalizer = text_normalizer
      @entries = {}
    end

    # Trusted SDK plugins register deterministic classifiers here. Domain is
    # optional for compatibility, but new specialized plugins should declare it.
    # Registering the same name replaces that plugin and keeps boot idempotent.
    def register(name:, route:, domain: "generic", fallback: false, matcher: nil, &block)
      callable = matcher || block
      route_name = route.to_s
      domain_name = domain.to_s
      raise ArgumentError, "classifier matcher must respond to call" unless callable&.respond_to?(:call)
      unless ROUTES.include?(route_name)
        raise ArgumentError, "unsupported classifier route #{route_name.inspect}"
      end
      unless DOMAINS.include?(domain_name)
        raise ArgumentError, "unsupported classifier domain #{domain_name.inspect}"
      end
      if fallback && domain_name != "generic"
        raise ArgumentError, "fallback classifiers must use the generic domain"
      end

      key = name.to_s.strip
      raise ArgumentError, "classifier name is required" if key.empty?
      existing = @entries[key]
      if existing && (existing.route != route_name || existing.domain != domain_name ||
                      existing.fallback != !!fallback)
        raise ArgumentError, "classifier #{key} is already registered with different routing metadata"
      end

      @entries[key] = Entry.new(
        name: key.freeze, domain: domain_name.freeze, route: route_name.freeze,
        matcher: callable, fallback: !!fallback
      ).freeze
      self
    end

    def classify(text, context = {})
      classify_internal(text, context, diagnostic: false).first
    end

    def classify_with_trace(text, context = {})
      classify_internal(text, context, diagnostic: true)
    end

    def detect_domain(text, context = {})
      raise ArgumentError, "classification context must be an object" unless context.is_a?(Hash)

      normalized = text_normalizer.normalize(text)
      result = domain_classifier.classify(normalized.matching, context)
      unless result.respond_to?(:domain) && DOMAINS.include?(result.domain.to_s)
        raise ArgumentError, "domain classifier returned an unsupported domain"
      end

      result
    end

    def registrations
      DOMAINS.each_with_object([]) do |domain, result|
        entries_for(domain, fallback: false).each do |entry|
          result << registration(entry)
        end
        entries_for(domain, fallback: true).each do |entry|
          result << registration(entry)
        end
      end.freeze
    end

    private

    def classify_internal(text, context, diagnostic:)
      raise ArgumentError, "classification context must be an object" unless context.is_a?(Hash)

      normalized = text_normalizer.normalize(text)
      domain_candidates = detected_domains(normalized.matching, context)
      domain = domain_candidates.max_by(&:confidence).domain
      loaded = []
      candidates = []

      entries = entries_for(domain, fallback: false)
      loaded.concat(entries.map(&:name))
      candidates.concat(evaluate(entries, normalized.original, context))

      if candidates.empty? && domain != "generic"
        entries = entries_for("generic", fallback: false)
        loaded.concat(entries.map(&:name))
        candidates.concat(evaluate(entries, normalized.original, context))
      end

      if candidates.empty?
        entries = entries_for("generic", fallback: true)
        loaded.concat(entries.map(&:name))
        candidates.concat(evaluate(entries, normalized.original, context))
      end

      selected = candidates.max_by { |candidate| candidate.fetch(:classification).confidence }
      classification = selected && selected.fetch(:classification)
      trace = diagnostic ? diagnostic_trace(
        normalized, domain_candidates, loaded, candidates, classification
      ) : nil
      [classification, trace]
    end

    def detected_domains(text, context)
      results = if domain_classifier.respond_to?(:candidates)
                  domain_classifier.candidates(text, context)
                else
                  [domain_classifier.classify(text, context)]
                end
      unless results.all? { |result| result.respond_to?(:domain) && DOMAINS.include?(result.domain.to_s) }
        raise ArgumentError, "domain classifier returned an unsupported domain"
      end

      results
    end

    def diagnostic_trace(normalized, domains, loaded, candidates, selected)
      {
        "normalized_text" => normalized.matching,
        "domain_candidates" => domains.map do |candidate|
          {
            "domain" => candidate.domain, "confidence" => candidate.confidence,
            "reason" => candidate.explanation
          }
        end,
        "loaded_classifier_plugins" => loaded.uniq,
        "intent_candidates" => candidates.map do |candidate|
          classification = candidate.fetch(:classification)
          {
            "intent" => classification.intent, "confidence" => classification.confidence,
            "plugin" => candidate.fetch(:entry).name
          }
        end,
        "selected_intent" => selected&.intent
      }.freeze
    end

    def registration(entry)
      {
        "name" => entry.name, "domain" => entry.domain,
        "route" => entry.route, "fallback" => entry.fallback
      }
    end

    def entries_for(domain, fallback:)
      @entries.values.select do |entry|
        entry.domain == domain && entry.fallback == fallback
      end.sort_by(&:name)
    end

    def evaluate(entries, source, context)
      entries.each_with_object([]) do |entry, result|
        plugin_result = entry.matcher.call(source, context)
        if plugin_result
          result << { classification: normalize(plugin_result, entry), entry: entry }.freeze
        end
      end
    end

    def normalize(result, entry)
      if result.is_a?(IntentClassification)
        return IntentClassification.new(
          intent: result.intent, confidence: result.confidence,
          route: entry.route, domain: entry.domain, explanation: result.explanation,
          slots: result.slots
        )
      end
      raise ArgumentError, "classifier #{entry.name} returned an invalid result" unless result.is_a?(Hash)

      data = result.each_with_object({}) { |(key, value), copy| copy[key.to_s] = value }
      explanation = data.key?("explanation") ? data.fetch("explanation") : data.fetch("reason")
      IntentClassification.new(
        intent: data.fetch("intent"), confidence: data.fetch("confidence"),
        route: entry.route, domain: entry.domain, explanation: explanation,
        slots: data.fetch("slots", {})
      )
    rescue KeyError => error
      raise ArgumentError, "classifier #{entry.name} result is missing #{error.key}"
    end
  end
end
