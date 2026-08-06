# frozen_string_literal: true

require_relative "lib/knowledge_sdk/version"

Gem::Specification.new do |spec|
  spec.name = "knowledge-sdk"
  spec.version = KnowledgeSDK::VERSION
  spec.summary = "Vault-independent Knowledge SDK for Obsidian Markdown knowledge graphs"
  spec.description = "CLI, Engine, Gateway, plugins, orchestration, capture inbox, extraction, planning, Dataset Engine, and deterministic cross-knowledge analysis for attached Obsidian Vaults."
  spec.authors = ["Knowledge SDK contributors"]
  spec.license = "MIT"
  spec.required_ruby_version = Gem::Requirement.new(">= 2.6")
  spec.files = Dir[
    "VERSION", "LICENSE", "README.md", "INSTALL.md", "AI_PROJECT_CONTEXT.md",
    "ARCHITECTURE_DECISIONS.md", "AGENTS.md", "bin/*", "lib/**/*.rb", "config/**/*", "docs/**/*",
    "plugins/**/*", "validators/**/*", "schemas/**/*", "templates/**/*",
    "adapters/**/*", "migrations/**/*", "acceptance/**/*"
  ].select { |path| File.file?(path) }
  spec.bindir = "bin"
  spec.executables = ["kg"]
  spec.require_paths = ["lib"]
  spec.add_runtime_dependency "sqlite3", ">= 1.3", "< 2.0"
  spec.add_development_dependency "minitest", ">= 5.11", "< 6.0"
  spec.add_development_dependency "rake", ">= 12.3", "< 14.0"
end
