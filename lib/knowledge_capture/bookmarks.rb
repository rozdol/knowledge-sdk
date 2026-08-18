# encoding: UTF-8
# frozen_string_literal: true

require "cgi"
require "date"
require "digest"
require "ipaddr"
require "net/http"
require "openssl"
require "resolv"
require "time"
require "timeout"
require "uri"

module KnowledgeCapture
  module Bookmarks
    RESOURCE_TYPES = %w[
      article personal_website portfolio gallery photo_gallery blog documentation project
      reference video_page product_page repository forum_thread unknown
    ].freeze
    FETCH_STATUSES = %w[not_attempted succeeded failed].freeze
    READING_STATUSES = %w[unread reading read].freeze
    TRACKING_PARAMETERS = %w[
      fbclid gclid dclid msclkid mc_cid mc_eid _ga _gl igshid vero_id oly_anon_id
      oly_enc_id wickedid yclid
    ].freeze
    MAX_URL_LENGTH = 4_096
    MAX_DOWNLOAD_BYTES = 1_048_576
    MAX_EXCERPT_LENGTH = 4_000

    class UrlNormalizer
      def normalize(value, base: nil)
        source = value.to_s.strip
        raise InvalidCapture, "bookmark URL is required" if source.empty?
        raise InvalidCapture, "bookmark URL exceeds #{MAX_URL_LENGTH} characters" if source.length > MAX_URL_LENGTH

        uri = base ? URI.join(base.to_s, source) : URI.parse(source)
        unless uri.is_a?(URI::HTTP) && %w[http https].include?(uri.scheme.to_s.downcase)
          raise InvalidCapture, "bookmark URL must use HTTP or HTTPS"
        end
        raise InvalidCapture, "bookmark URL requires a host" if uri.host.to_s.empty?
        raise InvalidCapture, "bookmark URL must not contain credentials" if uri.user || uri.password

        scheme = uri.scheme.downcase
        host = uri.host.downcase.sub(/\.\z/, "")
        raise InvalidCapture, "bookmark URL requires a host" if host.empty?
        port = uri.port
        port = nil if (scheme == "http" && port == 80) || (scheme == "https" && port == 443)
        path = uri.path.to_s.empty? ? "/" : uri.path
        query = normalized_query(uri.query)
        URI::Generic.build(
          scheme: scheme, host: host, port: port, path: path,
          query: query, fragment: nil
        ).normalize.to_s.freeze
      rescue URI::InvalidURIError, URI::BadURIError, ArgumentError => error
        raise InvalidCapture, "invalid bookmark URL: #{error.message}"
      end

      def domain(value)
        URI.parse(normalize(value)).host.to_s.downcase.freeze
      end

      private

      def normalized_query(query)
        return nil if query.to_s.empty?

        pairs = URI.decode_www_form(query, Encoding::UTF_8)
        kept = pairs.reject do |key, _value|
          name = key.to_s.downcase
          name.start_with?("utm_") || TRACKING_PARAMETERS.include?(name)
        end
        kept.empty? ? nil : URI.encode_www_form(kept)
      rescue ArgumentError
        raise InvalidCapture, "bookmark URL query is not valid UTF-8"
      end
    end

    class RequestParser
      URL = %r{https?://[^\s<>"']+}i.freeze
      STRONG_SIGNALS = /(?:
        \b(?:bookmark|remember|save|keep|add)\b.*\b(?:link|page|site|website|article|resource|reference|portfolio|gallery|blog|documentation|repository)\b|
        \bbookmark\s+this\b|
        (?:сохрани|запомни|добавь)\b.*(?:ссылк|страниц|сайт|стать|ресурс|источник|портфолио|галере|блог|документац|репозитор)|
        (?:сохрани|запомни)\b|
        (?:αποθήκευσε|θυμήσου|πρόσθεσε)\b.*(?:σύνδεσ|σελίδ|ιστότοπ|άρθρ|πόρτφολιο|γκαλερί|ιστολόγ|τεκμηρίωσ)
      )/ix.freeze
      INTEREST_SIGNALS = /(?:
        \binteresting\s+(?:[\p{L}-]+\s+){0,3}(?:link|page|site|website|article|portfolio|gallery|resource)\b|
        интересн(?:ая|ый|ое)\s+(?:[\p{L}-]+\s+){0,3}(?:ссылк\p{L}*|страниц\p{L}*|сайт\p{L}*|стать\p{L}*|портфолио|галере\p{L}*|ресурс\p{L}*)|
        ενδιαφέρουσ(?:α|ος|ο)\s+(?:[\p{L}-]+\s+){0,3}(?:σύνδεσ\p{L}*|σελίδ\p{L}*|ιστότοπ\p{L}*|άρθρ\p{L}*|γκαλερί\p{L}*)
      )/ix.freeze
      LEADING_DIRECTIVE = /\A\s*(?:
        (?:bookmark(?:\s+this)?|remember|save|keep|add)(?:\s+(?:this|the|that|to\s+my))?(?:\s+(?:link|page|site|website|article|resource|reference|portfolio|gallery|blog|documentation|repository))?|
        (?:сохрани|запомни|добавь)(?:\s+(?:эту|этот|это|в\s+мою))?(?:\s+(?:ссылку|страницу|сайт|статью|ресурс|источник|портфолио|галерею|блог|документацию|репозиторий))?|
        (?:αποθήκευσε|θυμήσου|πρόσθεσε)(?:\s+(?:αυτόν|αυτή|αυτό|στη\s+συλλογή\s+μου))?(?:\s+(?:τον\s+σύνδεσμο|τη\s+σελίδα|τον\s+ιστότοπο|το\s+άρθρο|το\s+πόρτφολιο|τη\s+γκαλερί))?
      )\s*(?:[.:;—-]+\s*)?/ix.freeze
      COLLECTION = /(?:
        (?:to|into)\s+my\s+collection\s+(?:of\s+)?([^:\n.]+)|
        в\s+мою\s+коллекци(?:ю|и)\s+([^:\n.]+)|
        στη\s+συλλογή\s+μου\s+([^:\n.]+)
      )/ix.freeze

      def initialize(normalizer: UrlNormalizer.new)
        @normalizer = normalizer
      end

      def parse(text)
        source = text.to_s.strip
        raw_urls = source.scan(URL).map { |value| trim_url(value) }.uniq
        return nil if raw_urls.empty?
        return nil unless STRONG_SIGNALS.match?(source) || INTEREST_SIGNALS.match?(source)
        raise InvalidCapture, "bookmark capture accepts exactly one URL" if raw_urls.length > 1

        normalized_url = @normalizer.normalize(raw_urls.first)
        note = user_note(source, raw_urls.first)
        collection = collection(source)
        resource_type = ResourceClassifier.new.classify(text: source, url: normalized_url)
        topics = TopicClassifier.new.classify(source, resource_type: resource_type)
        {
          "kind" => "bookmark", "body" => note.empty? ? normalized_url : note,
          "user_note" => note, "title" => fallback_title(note, normalized_url, resource_type),
          "language" => language(note.empty? ? source.sub(raw_urls.first, "") : note),
          "confidence" => 0.98,
          "url" => raw_urls.first, "normalized_url" => normalized_url,
          "domain" => @normalizer.domain(normalized_url), "resource_type" => resource_type,
          "topics" => topics, "collections" => collection ? [collection] : []
        }.freeze
      end

      private

      def trim_url(value)
        value.to_s.sub(/[\]\[)}>.,;:!?]+\z/, "")
      end

      def user_note(source, url)
        without_url = source.sub(url, "").strip
        without_collection = without_url.sub(COLLECTION, "").strip
        note = if INTEREST_SIGNALS.match?(source) && !STRONG_SIGNALS.match?(source)
                 without_collection
               else
                 without_collection.sub(LEADING_DIRECTIVE, "")
               end
        note.sub(/\A[.:;—-]+\s*/, "").sub(/\s*[:;—-]+\z/, "").strip.freeze
      end

      def collection(source)
        match = COLLECTION.match(source)
        return nil unless match

        match.captures.compact.first.to_s.strip.freeze
      end

      def fallback_title(note, url, resource_type)
        return title(note) unless note.empty?

        label = resource_type == "unknown" ? "Web reference" : resource_type.tr("_", " ").split.map(&:capitalize).join(" ")
        "#{label} — #{@normalizer.domain(url)}".freeze
      end

      def title(value)
        line = value.lines.first.to_s.strip.sub(/[.!?。]+\z/, "")
        line = value.strip if line.empty?
        line.length > 160 ? "#{line[0, 157].rstrip}..." : line
      end

      def language(value)
        scripts = []
        scripts << "ru" if value.match?(/[А-Яа-яЁё]/)
        scripts << "el" if value.match?(/\p{Greek}/u)
        scripts << "en" if value.match?(/[A-Za-z]/)
        scripts.length > 1 ? "mixed" : (scripts.first || "und")
      end
    end

    class ResourceClassifier
      RULES = [
        ["photo_gallery", /(?:photo\s*gallery|photography\s*gallery|фотогалере|галере[яи]\s+фотограф|φωτογραφικ\p{L}*\s+γκαλερί)/i],
        ["personal_website", /(?:personal\s+(?:website|site|page)|персональн\p{L}*\s+(?:сайт|страниц)|личн\p{L}*\s+сайт|προσωπικ\p{L}*\s+(?:ιστότοπ|σελίδ))/i],
        ["portfolio", /(?:\bportfolio\b|портфолио|χαρτοφυλάκιο|πόρτφολιο)/i],
        ["article", /(?:\barticle\b|стать[яиюе]|άρθρ\p{L}*)/i],
        ["documentation", /(?:\bdocs?\b|documentation|документац|τεκμηρίωσ)/i],
        ["repository", /(?:\brepositor(?:y|ies)\b|репозитор|αποθετήρι)/i],
        ["forum_thread", /(?:forum\s+thread|discussion\s+thread|ветк\p{L}*\s+форум|форум|νήμα\s+φόρουμ)/i],
        ["video_page", /(?:\bvideo\b|видео|βίντεο)/i],
        ["product_page", /(?:product\s+page|страниц\p{L}*\s+товар|карточк\p{L}*\s+товар|σελίδ\p{L}*\s+προϊόν)/i],
        ["blog", /(?:\bblog\b|блог|ιστολόγιο)/i],
        ["gallery", /(?:\bgaller(?:y|ies)\b|галере|γκαλερί)/i],
        ["project", /(?:\bproject\b|проект|έργο)/i],
        ["reference", /(?:\breference\b|справочн|источник|αναφορά)/i]
      ].freeze

      def classify(text:, url:, metadata: {})
        source = [text, metadata["type"], metadata["og_type"], metadata["title"]].compact.join(" ")
        RULES.each { |kind, pattern| return kind if source.match?(pattern) }
        host = URI.parse(url.to_s).host.to_s.downcase
        path = URI.parse(url.to_s).path.to_s.downcase
        return "repository" if host.match?(/(?:github|gitlab|codeberg)\./)
        return "video_page" if host.match?(/(?:youtube|youtu\.be|vimeo)\./)
        return "documentation" if host.start_with?("docs.") || path.match?(%r{/(?:docs?|documentation)/})
        return "blog" if host.start_with?("blog.") || path.match?(%r{/blog/})
        return "forum_thread" if path.match?(%r{/(?:thread|topic|discussion)s?/})
        return "article" if metadata["og_type"].to_s.downcase.include?("article")

        "unknown"
      rescue URI::InvalidURIError
        "unknown"
      end
    end

    class TopicClassifier
      RULES = {
        "street-photography" => /(?:street[\s-]+photograph|уличн\p{L}*\s+фотограф|φωτογραφ\p{L}*\s+δρόμου)/i,
        "photography" => /(?:photograph|photographer|photo\b|фотограф|φωτογραφ)/i,
        "personal-websites" => /(?:personal[\s-]+(?:website|site|page)|персональн\p{L}*\s+(?:сайт|страниц)|προσωπικ\p{L}*\s+(?:ιστότοπ|σελίδ))/i,
        "online-galleries" => /(?:online[\s-]+galler|онлайн[\s-]+галере|διαδικτυακ\p{L}*\s+γκαλερί)/i,
        "web-design" => /(?:web[\s-]+design|веб[\s-]+дизайн|σχεδιασμ\p{L}*\s+ιστοσελίδ)/i,
        "trading" => /(?:\btrading\b|трейдинг|торгов\p{L}*\s+стратег|συναλλαγ)/i,
        "AI" => /(?:\bAI\b|artificial\s+intelligence|искусственн\p{L}*\s+интеллект|τεχνητ\p{L}*\s+νοημοσύν)/i
      }.freeze

      def classify(text, resource_type: nil)
        source = text.to_s
        topics = RULES.each_with_object([]) do |(topic, pattern), result|
          result << topic if source.match?(pattern)
        end
        topics << "personal-websites" if resource_type == "personal_website"
        topics << "online-galleries" if %w[gallery photo_gallery].include?(resource_type) && source.match?(/online|онлайн|διαδικτυακ/i)
        topics.uniq.sort.freeze
      end
    end

    class FetchError < StandardError; end

    class WebMetadataFetcher
      BLOCKED_NETWORKS = %w[
        0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16
        172.16.0.0/12 192.0.0.0/24 192.0.2.0/24 192.168.0.0/16 198.18.0.0/15
        198.51.100.0/24 203.0.113.0/24 224.0.0.0/4 240.0.0.0/4
        ::/128 ::1/128 fc00::/7 fe80::/10 ff00::/8 2001:db8::/32
      ].map { |value| IPAddr.new(value) }.freeze
      REDIRECT_LIMIT = 3

      def initialize(normalizer: UrlNormalizer.new, environment: ENV, resolver: Resolv,
                     open_timeout: 3, read_timeout: 5)
        @normalizer = normalizer
        @environment = environment
        @resolver = resolver
        @open_timeout = open_timeout
        @read_timeout = read_timeout
      end

      def fetch(url)
        return { "status" => "not_attempted" }.freeze unless enabled?

        current = @normalizer.normalize(url)
        redirects = []
        (REDIRECT_LIMIT + 1).times do
          response = request(current)
          if response.fetch("redirect")
            target = @normalizer.normalize(response.fetch("redirect"), base: current)
            if URI.parse(current).scheme == "https" && URI.parse(target).scheme == "http"
              raise FetchError, "HTTPS bookmark redirect cannot downgrade to HTTP"
            end
            raise FetchError, "redirect loop detected" if redirects.include?(target) || target == current

            redirects << current
            current = target
            next
          end
          metadata = HtmlMetadataExtractor.new(normalizer: @normalizer).extract(
            response.fetch("body"), base_url: current
          )
          return metadata.merge(
            "status" => "succeeded", "final_url" => current,
            "content_type" => response.fetch("content_type"), "redirects" => redirects
          ).freeze
        end
        raise FetchError, "too many redirects"
      rescue InvalidCapture => error
        raise FetchError, error.message
      end

      private

      def enabled?
        !%w[0 false no off disabled].include?(@environment.fetch("KG_BOOKMARK_FETCH", "on").to_s.downcase)
      end

      def request(url)
        uri = URI.parse(url)
        address = resolved_public_address(uri.host)
        http = Net::HTTP.new(uri.host, uri.port)
        if http.respond_to?(:ipaddr=)
          http.ipaddr = address
        else
          # Ruby 2.6 has no public ipaddr= but Net::HTTP connects through this
          # private method. Pinning its per-instance result keeps TLS SNI and
          # Host bound to the original public hostname while preventing a
          # second DNS lookup after the SSRF check.
          pinned = address
          http.define_singleton_method(:conn_address) { pinned }
          http.singleton_class.send(:private, :conn_address)
        end
        http.open_timeout = @open_timeout
        http.read_timeout = @read_timeout
        if uri.scheme == "https"
          http.use_ssl = true
          http.verify_mode = OpenSSL::SSL::VERIFY_PEER
        end
        request = Net::HTTP::Get.new(uri.request_uri)
        request["User-Agent"] = "knowledge-sdk/#{KnowledgeSDK::VERSION} bookmark-metadata"
        request["Accept"] = "text/html,application/xhtml+xml;q=0.9"
        request["Accept-Encoding"] = "identity"
        body = +""
        response = Timeout.timeout(@open_timeout + @read_timeout + 2) do
          http.request(request) do |reply|
            if reply.is_a?(Net::HTTPRedirection)
              break reply
            end
            unless reply.is_a?(Net::HTTPSuccess)
              raise FetchError, "bookmark fetch returned HTTP #{reply.code}"
            end
            content_type = reply["content-type"].to_s.downcase
            unless content_type.empty? || content_type.include?("text/html") || content_type.include?("application/xhtml+xml")
              raise FetchError, "bookmark fetch returned unsupported content type"
            end
            length = reply["content-length"].to_i
            raise FetchError, "bookmark page exceeds the download limit" if length > MAX_DOWNLOAD_BYTES
            reply.read_body do |chunk|
              body << chunk
              raise FetchError, "bookmark page exceeds the download limit" if body.bytesize > MAX_DOWNLOAD_BYTES
            end
            break [reply, content_type]
          end
        end
        if response.is_a?(Net::HTTPRedirection)
          location = response["location"].to_s
          raise FetchError, "bookmark redirect is missing a location" if location.empty?
          return { "redirect" => location }
        end

        _reply, content_type = response
        { "redirect" => nil, "body" => utf8(body), "content_type" => content_type }
      rescue Timeout::Error, SocketError, SystemCallError, OpenSSL::SSL::SSLError,
             IOError, EOFError, URI::InvalidURIError => error
        raise FetchError, error.message
      end

      def resolved_public_address(host)
        name = host.to_s.downcase
        if name == "localhost" || name.end_with?(".localhost", ".local", ".internal")
          raise FetchError, "bookmark host is not public"
        end
        resolved = Timeout.timeout(@open_timeout) { @resolver.getaddresses(name) }
        addresses = resolved.map { |value| IPAddr.new(value) }
        raise FetchError, "bookmark host could not be resolved" if addresses.empty?
        raise FetchError, "bookmark host resolves to a non-public address" if addresses.any? { |ip| blocked?(ip) }

        addresses.sort_by(&:to_s).first.to_s
      rescue IPAddr::InvalidAddressError, Resolv::ResolvError, Timeout::Error
        raise FetchError, "bookmark host could not be resolved"
      end

      def blocked?(address)
        BLOCKED_NETWORKS.any? { |network| network.include?(address) }
      end

      def utf8(value)
        value.to_s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "�")
      end
    end

    class HtmlMetadataExtractor
      def initialize(normalizer: UrlNormalizer.new)
        @normalizer = normalizer
      end

      def extract(html, base_url:)
        source = html.to_s
        meta = meta_values(source)
        title = first(meta["og:title"], title_value(source))
        description = first(meta["og:description"], meta["description"], meta["twitter:description"])
        author = first(meta["author"], meta["article:author"])
        published_at = normalized_time(first(
          meta["article:published_time"], meta["date"], meta["datepublished"], meta["publishdate"]
        ))
        canonical = canonical_url(source, base_url)
        excerpt = excerpt(source)
        language = html_language(source)
        {
          "title" => bounded(title, 500), "description" => bounded(description, 2_000),
          "author_name" => bounded(author, 500), "published_at" => published_at,
          "page_language" => bounded(language, 50), "canonical_url" => canonical,
          "og_type" => bounded(meta["og:type"], 100), "content_excerpt" => excerpt,
          "content_hash" => excerpt.empty? ? nil : Digest::SHA256.hexdigest(excerpt)
        }.reject { |_key, value| value.nil? || value.to_s.empty? }
      end

      private

      def meta_values(source)
        source.scan(/<meta\b[^>]*>/im).each_with_object({}) do |tag, result|
          attrs = attributes(tag)
          key = attrs["property"] || attrs["name"] || attrs["itemprop"]
          content = attrs["content"]
          result[key.to_s.downcase] ||= clean(content) if key && content
        end
      end

      def attributes(tag)
        tag.scan(/([:\w-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))/m).each_with_object({}) do |parts, result|
          result[parts[0].downcase] = CGI.unescapeHTML(parts[1] || parts[2] || parts[3] || "")
        end
      end

      def title_value(source)
        match = source.match(/<title\b[^>]*>(.*?)<\/title>/im)
        match && clean(match[1])
      end

      def canonical_url(source, base_url)
        source.scan(/<link\b[^>]*>/im).each do |tag|
          attrs = attributes(tag)
          rel = attrs["rel"].to_s.downcase.split(/\s+/)
          next unless rel.include?("canonical") && !attrs["href"].to_s.empty?

          return @normalizer.normalize(attrs["href"], base: base_url)
        rescue InvalidCapture
          next
        end
        @normalizer.normalize(base_url)
      end

      def excerpt(source)
        value = source.gsub(/<(?:script|style|noscript|svg|template)\b[^>]*>.*?<\/\s*(?:script|style|noscript|svg|template)\s*>/im, " ")
                      .gsub(/<!--.*?-->/m, " ").gsub(/<[^>]+>/m, " ")
        clean(value)[0, MAX_EXCERPT_LENGTH].to_s.strip.freeze
      end

      def html_language(source)
        match = source.match(/<html\b[^>]*>/im)
        match && attributes(match[0])["lang"].to_s.strip
      end

      def normalized_time(value)
        return nil if value.to_s.strip.empty?
        source = value.to_s.strip
        return Date.iso8601(source).iso8601 if source.match?(/\A\d{4}-\d{2}-\d{2}\z/)

        Time.iso8601(source).iso8601
      rescue ArgumentError
        nil
      end

      def clean(value)
        CGI.unescapeHTML(value.to_s.gsub(/<[^>]+>/m, " ")).gsub(/\s+/, " ").strip
      end

      def bounded(value, length)
        clean(value)[0, length].to_s.strip
      end

      def first(*values)
        values.find { |value| !value.to_s.strip.empty? }
      end
    end

    class DuplicateDetector
      def initialize(vault_root:, normalizer: UrlNormalizer.new)
        @store = Store.new(vault_root: vault_root)
        @normalizer = normalizer
      end

      def find(url:, canonical_url: nil, content_hash: nil)
        urls = [url, canonical_url].compact.map { |value| safe_normalize(value) }.compact.uniq
        bookmarks.each do |capture|
          existing = [capture.url, capture.canonical_url].compact.map { |value| safe_normalize(value) }.compact.uniq
          overlap = urls & existing
          unless overlap.empty?
            return result(capture, "canonical_url", exact: true, matched_url: overlap.first)
          end
        end
        if content_hash.to_s.match?(/\A[0-9a-f]{64}\z/)
          capture = bookmarks.find { |item| item.content_hash == content_hash.to_s }
          return result(capture, "content_hash", exact: false) if capture
        end
        nil
      end

      private

      def bookmarks
        @store.all.select { |capture| capture.kind == "bookmark" && capture.status != "deleted" }
      end

      def safe_normalize(value)
        @normalizer.normalize(value)
      rescue InvalidCapture
        nil
      end

      def result(capture, reason, exact:, matched_url: nil)
        {
          "capture" => capture, "reason" => reason, "exact" => exact,
          "matched_url" => matched_url
        }.freeze
      end
    end
  end
end
