# frozen_string_literal: true

require_relative "knowledge_capture/errors"
require_relative "knowledge_capture/bookmarks"
require_relative "knowledge_capture/capture"
require_relative "knowledge_capture/store"
require_relative "knowledge_capture/plugins"

module KnowledgeCapture
  VERSION = KnowledgeSDK::VERSION

  class << self
    def registry
      @registry ||= PluginRegistry.new
    end
  end
end

require_relative "knowledge_capture/linker"
require_relative "knowledge_capture/manager"
require_relative "knowledge_capture/search"
require_relative "knowledge_capture/routing"
require_relative "knowledge_capture/proposals"
require_relative "knowledge_capture/cli"

KnowledgeCapture::IntentClassifierPlugin.register
