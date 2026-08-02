# frozen_string_literal: true

module KnowledgeSDK
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
        /(?:лекарств|препарат|принимаю|таблет|доз|давлен|пульс|частот[[:alpha:]]*\s+сердц|\bвес\b|тали|температур[[:alpha:]]*\s+тел|сатурац|анализ|лаборатор|холестерин|глюкоз|гемоглобин|лпнп|лпвп)/i,
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

    def classify(text, context = {})
      source = text.to_s.strip
      raise ArgumentError, "classification text is empty" if source.empty?
      raise ArgumentError, "classification context must be an object" unless context.is_a?(Hash)

      matches = DOMAIN_RULES.each_with_object([]) do |(domain, patterns), result|
        result << domain if patterns.any? { |pattern| pattern.match?(source) }
      end
      domain = matches.max_by { |candidate| DOMAIN_CONFIDENCE.fetch(candidate) } || "generic"
      confidence = DOMAIN_CONFIDENCE.fetch(domain, 0.0)
      explanation = if domain == "generic"
                      "no specialized semantic domain was detected"
                    else
                      "detected #{domain} vocabulary and concepts"
                    end
      DomainClassification.new(
        domain: domain, confidence: confidence, explanation: explanation
      )
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

    attr_reader :domain_classifier

    def initialize(domain_classifier: SemanticDomainClassifier.new)
      unless domain_classifier.respond_to?(:classify)
        raise ArgumentError, "domain classifier must respond to classify"
      end

      @domain_classifier = domain_classifier
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
      source = text.to_s.strip
      raise ArgumentError, "classification text is empty" if source.empty?
      raise ArgumentError, "classification context must be an object" unless context.is_a?(Hash)

      domain = detect_domain(source, context).domain
      classification = best_match(entries_for(domain, fallback: false), source, context)
      return classification if classification

      if domain != "generic"
        classification = best_match(entries_for("generic", fallback: false), source, context)
        return classification if classification
      end

      best_match(entries_for("generic", fallback: true), source, context)
    end

    def detect_domain(text, context = {})
      result = domain_classifier.classify(text, context)
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

    def best_match(entries, source, context)
      matches = entries.each_with_object([]) do |entry, result|
        plugin_result = entry.matcher.call(source, context)
        result << normalize(plugin_result, entry) if plugin_result
      end
      matches.max_by(&:confidence)
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
