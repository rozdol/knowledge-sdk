# frozen_string_literal: true

require "knowledge_graph"
require "rack"
require "rackup/handler/webrick"
require "tzinfo"
require "tzinfo/data"
require "securerandom"
require "openssl"
require "uri"
module KnowledgeSDK
  module Dashboard
    ROOT = File.expand_path("../..", __dir__).freeze
  end
end
require_relative "dashboard/settings"
require_relative "dashboard/sessions"
require_relative "dashboard/bridge"
require_relative "dashboard/app"
require_relative "dashboard/server"
