# frozen_string_literal: true

module KnowledgeSDK
  module Dashboard
    # Only package-owned sources enter this graph. No request/Vault path is read.
    class Assets
      PAGES = %w[/ /search /contacts /memory /finance /medical /agenda /learning].freeze
      TYPES = { ".js" => "text/javascript; charset=utf-8", ".css" => "text/css; charset=utf-8", ".svg" => "image/svg+xml" }.freeze

      def initialize(root: ROOT)
        @routes = {}
        api = add(root, "api.js")
        widgets = add(root, "widgets.js")
        app = add(root, "app.js", '"./api.js"' => api, '"./widgets.js"' => widgets)
        css = add(root, "styles.css")
        mark = add(root, "mark.svg")
        html = File.read(File.join(root, "assets", "index.html"))
        html = html.gsub("__APP_MODULE__", app).gsub("__STYLESHEET__", css).gsub("__MARK__", mark).freeze
        PAGES.each { |path| @routes[path] = ["text/html; charset=utf-8", html].freeze }
        @routes.freeze
      end

      def include?(path)
        @routes.key?(path)
      end

      def fetch(path)
        @routes.fetch(path)
      end

      private

      def add(root, filename, substitutions = {})
        content = File.read(File.join(root, "assets", filename))
        substitutions.each { |key, value| content = content.gsub(key, value.inspect) }
        extension = File.extname(filename)
        url = "/assets/#{File.basename(filename, extension)}-#{Digest::SHA256.hexdigest(content)[0, 24]}#{extension}"
        @routes[url] = [TYPES.fetch(extension), content.freeze].freeze
        url.freeze
      end
    end
  end
end
