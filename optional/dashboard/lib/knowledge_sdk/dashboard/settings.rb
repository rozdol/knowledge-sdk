# frozen_string_literal: true

module KnowledgeSDK
  module Dashboard
    class Settings
      PERMISSIONS = %w[graph:read capture:read intelligence:read graph:private graph:restricted
                       capture:restricted dataset:read dataset:restricted finance:read finance:restricted
                       activity:read health:read orchestration:read notification:read].freeze
      attr_reader :vault, :timezone, :secret_digest, :port, :permissions, :display_label, :dataset_path

      def initialize(vault:, timezone:, secret_file:, port: 8765, settings_file: nil,
                     config_path: KnowledgeSDK.config_path, dataset_path: nil)
        raise ConfigurationError, "dashboard requires --vault" if vault.to_s.empty?
        configuration = Configuration.new(path: config_path)
        registry = VaultRegistry.new(configuration: configuration)
        @vault = VaultLocator.new(registry: registry).resolve(explicit: vault).path.to_s.freeze
        TZInfo::DataSource.set(:ruby)
        @timezone = TZInfo::Timezone.get(timezone.to_s).identifier.freeze
        @port = Integer(port)
        raise ConfigurationError, "dashboard port must be 1024-65535" unless @port.between?(1024, 65535)
        secret = operator_file(secret_file).strip
        unless secret.match?(/\A[A-Za-z0-9_-]{43,128}\z/)
          raise ConfigurationError, "secret must encode at least 32 random bytes as base64url"
        end
        @secret_digest = Digest::SHA256.digest(secret).freeze
        values = settings_file ? JSON.parse(operator_file(settings_file)) : {}
        keys = %w[version permissions display_label schedule_config execution_timezone]
        unless values.is_a?(Hash) && (values.keys - keys).empty? && values.fetch("version", 1) == 1
          raise ConfigurationError, "unsupported dashboard settings"
        end
        grants = values.fetch("permissions", %w[graph:read capture:read intelligence:read])
        unless grants.is_a?(Array) && (grants - PERMISSIONS).empty?
          raise ConfigurationError, "unsupported dashboard permissions"
        end
        @permissions = grants.uniq.freeze
        @display_label = values.fetch("display_label", "Knowledge dashboard")
        unless @display_label.is_a?(String) && @display_label.length.between?(1, 100)
          raise ConfigurationError, "invalid display label"
        end
        @display_label = @display_label.freeze
        # Operational inventory is P6; accept no unvalidated future configuration.
        if values["schedule_config"] || values["execution_timezone"]
          raise ConfigurationError, "schedule configuration is not available in P1"
        end
        configured = dataset_path || ENV["KG_DATASET_DB"] || configuration.dataset_db
        candidate = configured.to_s.empty? ? Pathname.new(KnowledgeSDK::DATASET_PATH) : Pathname.new(configured)
        @dataset_path = if candidate.absolute? || configured.to_s.start_with?("~")
                          candidate.expand_path.to_s
                        else
                          File.expand_path(candidate.to_s, @vault)
                        end.freeze
        freeze
      rescue TZInfo::InvalidTimezoneIdentifier, ArgumentError, TypeError, JSON::ParserError
        raise ConfigurationError, "invalid dashboard configuration"
      end

      def origin
        "http://127.0.0.1:#{port}"
      end

      def reader
        StructuredDataset::Reader.new(vault_root: vault, database_path: dataset_path)
      end

      private

      def operator_file(path)
        filename = File.expand_path(path.to_s)
        stat = File.lstat(filename)
        real = File.realpath(filename)
        if !stat.file? || stat.symlink? || stat.uid != Process.uid || (stat.mode & 0o077) != 0 ||
           real == vault || real.start_with?(vault + File::SEPARATOR) || stat.size > 16_384
          raise ConfigurationError, "operator file must be owner-only, regular and outside the Vault"
        end
        File.read(filename)
      rescue SystemCallError
        raise ConfigurationError, "operator file is unavailable"
      end
    end
  end
end
