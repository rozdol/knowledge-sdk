# frozen_string_literal: true

require_relative "../../lib/knowledge_sdk/version"

Gem::Specification.new do |spec|
  spec.name = "knowledge-sdk-dashboard"
  spec.version = KnowledgeSDK::VERSION
  spec.summary = "Optional authenticated local read-only Knowledge SDK dashboard host"
  spec.authors = ["Knowledge SDK contributors"]
  spec.license = "MIT"
  spec.required_ruby_version = ">= 2.6"
  spec.files = Dir["lib/**/*.rb", "config/*.json", "assets/*", "README.md", "LICENSE"]
  spec.require_paths = ["lib"]
  spec.add_runtime_dependency "knowledge-sdk", "= #{KnowledgeSDK::VERSION}"
  { "rack" => "3.2.7", "rackup" => "2.3.1", "webrick" => "1.9.2",
    "tzinfo" => "2.0.6", "concurrent-ruby" => "1.3.8", "tzinfo-data" => "1.2026.5" }.each do |name, version|
    spec.add_runtime_dependency name, "= #{version}"
  end
end
