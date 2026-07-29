# frozen_string_literal: true

require "fileutils"
require "open3"
require "pathname"
require "rbconfig"
require "tmpdir"

module KnowledgeGraph
  class ExternalValidator
    def initialize(vault_root:, validator_path:)
      @vault_root = Pathname.new(vault_root)
      @validator_path = Pathname.new(validator_path)
    end

    def call(context)
      Dir.mktmpdir("knowledge-graph-candidate-") do |candidate|
        copy_validation_surface(candidate)
        context.transaction.materialize_to(candidate)
        stdout, stderr, status = Open3.capture3(
          { "VAULT_ROOT" => candidate }, RbConfig.ruby, @validator_path.to_s
        )
        return true if status.success?

        message = [stderr, stdout].reject(&:empty?).join("\n").strip
        raise ValidationError, message
      end
    end

    private

    def copy_validation_surface(candidate)
      Dir.glob(@vault_root.join("**/*").to_s, File::FNM_DOTMATCH).sort.each do |source|
        path = Pathname.new(source)
        relative = path.relative_path_from(@vault_root).to_s
        next if relative == "." || relative.start_with?(".git/", ".obsidian/")
        next unless path.file? && validation_relevant?(relative)

        destination = Pathname.new(candidate).join(relative)
        FileUtils.mkdir_p(destination.dirname)
        FileUtils.copy_file(path, destination)
      end
    end

    def validation_relevant?(relative)
      relative.end_with?(".md", ".icloud") || File.basename(relative).downcase.include?("conflicted copy")
    end
  end
end
