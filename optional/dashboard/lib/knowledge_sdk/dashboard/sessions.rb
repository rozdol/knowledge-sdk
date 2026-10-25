# frozen_string_literal: true

module KnowledgeSDK
  module Dashboard
    class HTTPError < StandardError
      attr_reader :status, :code
      def initialize(status, code)
        @status, @code = status, code
        super(code)
      end
    end

    class Sessions
      COOKIE = "kg_dashboard_session".freeze

      def initialize(clock:, permissions:, on_revoke:)
        @clock, @permissions, @on_revoke = clock, permissions, on_revoke
        @sessions, @counters = {}, {}
        @mutex = Mutex.new
      end

      def fetch(id)
        @mutex.synchronize { prune!; @sessions[id] }
      end

      def create(authenticated: false)
        @mutex.synchronize do
          prune!
          raise HTTPError.new(429, "rate_limited") if @sessions.values.count { |s| s[:authenticated] == authenticated } >= 20
          id = SecureRandom.urlsafe_base64(32)
          now = @clock.call
          @sessions[id] = {
            id: id, csrf_token: SecureRandom.urlsafe_base64(32), authenticated: authenticated,
            created_at: now, active_at: now,
            agent: AgentPlatform::AgentIdentity.new(id: "dashboard:#{SecureRandom.hex(16)}", permissions: @permissions,
              attributes: { allowed_capabilities: Bridge::ALLOWED })
          }.freeze
        end
      end

      def touch(session)
        @mutex.synchronize do
          current = @sessions[session[:id]]
          @sessions[session[:id]] = current.merge(active_at: @clock.call).freeze if current
        end
      end

      def revoke(id)
        @mutex.synchronize { remove!(id) }
      end

      def clear
        @mutex.synchronize { @sessions.keys.each { |id| remove!(id) }; @counters.clear }
      end

      def throttle!(key, maximum)
        @mutex.synchronize do
          now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          @counters.delete_if { |_name, entry| entry[0] <= now - 60 }
          # Keys derive only from bounded server session IDs or fixed global keys.
          raise HTTPError.new(429, "rate_limited") if !@counters.key?(key) && @counters.length >= 100
          entry = @counters[key] ||= [now, 0]
          raise HTTPError.new(429, "rate_limited") if entry[1] >= maximum
          entry[1] += 1
        end
      end

      def expires_at(session)
        [session[:created_at] + (session[:authenticated] ? 28_800 : 300),
         session[:active_at] + (session[:authenticated] ? 1800 : 300)].min
      end

      private

      def remove!(id)
        removed = @sessions.delete(id)
        @on_revoke.call(removed[:agent].id) if removed
      end

      def prune!
        @sessions.keys.each { |id| remove!(id) if expires_at(@sessions.fetch(id)) <= @clock.call }
      end
    end
  end
end
