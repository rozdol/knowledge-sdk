# frozen_string_literal: true

module KnowledgeSDK
  module Dashboard
    class Cursors
      def initialize(clock:)
        @clock, @entries, @mutex = clock, {}, Mutex.new
      end

      def remove_agent(id)
        @mutex.synchronize { @entries.delete_if { |_key, entry| entry[:owner] == id } }
      end

      def issue(owner:, selector:, filters:, version:, after:)
        @mutex.synchronize do
          prune!
          raise HTTPError.new(429, "rate_limited") if @entries.length >= 1000 || @entries.values.count { |entry| entry[:owner] == owner } >= 100
          token = SecureRandom.urlsafe_base64(32)
          @entries[token] = { owner: owner, selector: selector, filters: filters.dup.freeze,
            version: version, after: after.freeze, expires: @clock.call + 300 }.freeze
          token
        end
      end

      def fetch(token, owner:, selector:, filters:)
        raise HTTPError.new(422, "invalid_arguments") unless token.match?(/\A[A-Za-z0-9_-]{43}\z/)
        @mutex.synchronize do
          prune!
          item = @entries[token]
          unless item && item[:owner] == owner && item[:selector] == selector && item[:filters] == filters
            raise HTTPError.new(409, "context_changed")
          end
          item
        end
      end

      private

      def prune!
        @entries.delete_if { |_key, entry| entry[:expires] <= @clock.call }
      end
    end
  end
end
