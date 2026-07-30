# frozen_string_literal: true

require "json"

module AgentPlatform
  module Generators
    module_function

    def markdown(registry)
      lines = ["# Capability Reference", ""]
      registry.list.each do |manifest|
        lines << "## #{manifest.name} (`#{manifest.capability_id}@#{manifest.version}`)" << ""
        lines << manifest.description << ""
        lines << "- Effects: `#{manifest.effects}`"
        lines << "- Risk: `#{manifest.risk}`"
        lines << "- Approval: `#{manifest.approval}`"
        lines << "- Permissions: #{manifest.permissions.map { |item| "`#{item}`" }.join(', ')}" << ""
        lines << "```json" << JSON.pretty_generate(manifest.input_schema) << "```" << ""
      end
      lines.join("\n")
    end

    def ruby_sdk(registry, module_name: "GeneratedCapabilitySDK")
      methods = registry.list.map do |manifest|
        method_name = manifest.name.gsub(/[^a-z0-9_]/i, "_")
        <<~RUBY
          def #{method_name}(arguments = {}, session_id: nil)
            invoke("#{manifest.capability_id}", "#{manifest.version}", arguments, session_id: session_id)
          end
        RUBY
      end.join("\n")
      <<~RUBY
        module #{module_name}
          #{methods.gsub("\n", "\n  ").rstrip}
        end
      RUBY
    end
  end
end
