# frozen_string_literal: true

module KnowledgeSDK
  module Dashboard
    # Bound raw parsing before WEBrick normalizes paths/headers or Rack dispatch.
    class BoundedRequest < WEBrick::HTTPRequest
      def meta_vars
        super.merge("REQUEST_URI" => unparsed_uri)
      end

      private

      def read_line(socket, _size = nil)
        limit = @request_line ? 16_384 : 8192
        line = super(socket, limit)
        if line && line.bytesize >= limit && !line.end_with?("\n")
          raise(@request_line ? WEBrick::HTTPStatus::RequestHeaderFieldsTooLarge : WEBrick::HTTPStatus::RequestURITooLarge)
        end
        if @request_line && line
          @dashboard_header_bytes = (@dashboard_header_bytes || 0) + line.bytesize
          raise WEBrick::HTTPStatus::RequestHeaderFieldsTooLarge if @dashboard_header_bytes > 16_384
        end
        line
      end
    end

    class SafeResponse < WEBrick::HTTPResponse
      def set_error(error, backtrace = false)
        super
        self.body = JSON.generate(status: "error", error: "invalid_http_request")
        self["content-type"] = "application/json"
        App::SECURITY_HEADERS.each { |key, value| self[key] = value }
      end
    end

    class Server < Rackup::Handler::WEBrick::Server
      def create_request(config)
        BoundedRequest.new(config)
      end

      def create_response(config)
        SafeResponse.new(config)
      end

      def service(request, response)
        raw = request.unparsed_uri.to_s
        if request.header.fetch("host", []).length != 1 || raw.match?(%r{\Ahttps?://|%(?:2f|5c|00|25)|(?:\A|/)\.{1,2}(?:/|\z)}i)
          raise WEBrick::HTTPStatus::BadRequest
        end
        super
      end

      def self.run(argv:, out:, err:, vault: nil, config_path: nil, dataset_path: nil)
        raise ConfigurationError, "expected dashboard serve" unless argv.shift == "serve"
        options = { vault: vault, config_path: config_path || KnowledgeSDK.config_path, dataset_path: dataset_path }
        OptionParser.new do |parser|
          parser.on("--vault PATH") { |value| options[:vault] = value }
          parser.on("--config PATH") { |value| options[:config_path] = value }
          parser.on("--dataset-db PATH") { |value| options[:dataset_path] = value }
          parser.on("--timezone IANA") { |value| options[:timezone] = value }
          parser.on("--secret-file FILE") { |value| options[:secret_file] = value }
          parser.on("--settings FILE") { |value| options[:settings_file] = value }
          parser.on("--port PORT", Integer) { |value| options[:port] = value }
        end.parse!(argv)
        unless argv.empty? && options[:timezone] && options[:secret_file]
          raise ConfigurationError, "dashboard requires --vault, --timezone and --secret-file"
        end
        settings = Settings.new(**options)
        app = App.new(settings, logger: err)
        server = new(app, BindAddress: "127.0.0.1", Port: settings.port, MaxClients: 8,
          RequestTimeout: 10, InputBufferSize: 4096, DoNotReverseLookup: true,
          AccessLog: [], Logger: WEBrick::Log.new(File::NULL, WEBrick::Log::FATAL))
        previous = {}
        %w[INT TERM].each { |signal| previous[signal] = Signal.trap(signal) { server.shutdown } }
        out.puts("Dashboard: #{settings.origin}")
        out.flush
        server.start
        0
      rescue SystemCallError
        raise ConfigurationError, "dashboard listener is unavailable"
      ensure
        previous&.each { |signal, handler| Signal.trap(signal, handler) }
        server&.shutdown
        app&.close
      end
    end
  end
end
