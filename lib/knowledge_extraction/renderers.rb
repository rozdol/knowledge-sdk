# frozen_string_literal: true

module KnowledgeExtraction
  class MarkdownProposalRenderer
    def render(proposal)
      data = proposal.respond_to?(:to_h) ? Support.canonical(proposal.to_h) : proposal
      source = data.fetch("source")
      lines = [
        "# Knowledge Extraction Proposal",
        "",
        "- Proposal: `#{data.fetch('proposal_id')}`",
        "- Status: `#{data.fetch('status')}`",
        "- Ingestion: `#{data.fetch('ingestion_state')}`",
        "- Source: #{source.fetch('source_type')} (`#{source.fetch('source_id')}`)",
        "- Language: #{source.fetch('language')}",
        "",
        "## Summary",
        "",
        data.fetch("summary").to_s,
        "",
        "## Detected entities",
        ""
      ]
      decisions = data.fetch("resolution_decisions").to_h { |item| [item.fetch("mention_id"), item] }
      data.fetch("entity_mentions").each do |mention|
        decision = decisions.fetch(mention.fetch("mention_id"))
        lines << "- #{mention.fetch('display_name')} — #{mention.fetch('entity_type')}; #{decision.fetch('outcome')}"
      end
      lines.concat(["", "## Extracted facts", ""])
      data.fetch("facts").each_with_index do |fact, index|
        object = fact.fetch("object")
        object_text = object["display_name"] || object["normalized_value"] || object["value"]
        qualifier = fact.fetch("inference") ? "inference" : "statement"
        lines << "#{index + 1}. **#{qualifier}**: #{fact.fetch('subject').fetch('display_name')} " \
                 "#{fact.fetch('predicate')} #{object_text} — #{fact.fetch('status')}, confidence #{format('%.2f', fact.fetch('confidence'))}"
      end
      lines.concat(["", "## Proposed graph changes", ""])
      data.fetch("planned_intents").each_with_index do |planned, index|
        blocked = planned.fetch("blocked_reasons")
        suffix = blocked.empty? ? "ready for review" : "BLOCKED: #{blocked.join('; ')}"
        lines << "#{index + 1}. `#{planned.fetch('intent').fetch('type')}` — #{planned.fetch('risk')} risk; " \
                 "#{planned.fetch('approval_requirement')}; #{suffix}"
      end
      lines.concat(["", "## Warnings and conflicts", ""])
      warnings = data.fetch("warnings") + data.fetch("conflicts")
      warnings.empty? ? lines << "- None" : warnings.each { |warning| lines << "- #{warning}" }
      lines.concat(["", "## Approval", ""])
      approvals = data.fetch("required_approvals")
      lines << "- #{approvals.fetch('total')} operation(s) require approval"
      lines << "- #{approvals.fetch('blocked')} operation(s) are blocked"
      lines << ""
      lines.join("\n")
    end
  end

  class ConciseProposalRenderer
    def render(proposal)
      data = proposal.respond_to?(:to_h) ? Support.canonical(proposal.to_h) : proposal
      intents = data.fetch("planned_intents")
      blocked = intents.count { |item| !item.fetch("blocked_reasons").empty? }
      [
        "Proposal #{data.fetch('proposal_id')}",
        "Source: #{data.fetch('source').fetch('source_type')} / #{data.fetch('source').fetch('language')}",
        "Ingestion: #{data.fetch('ingestion_state')}",
        "Facts: #{data.fetch('facts').length}; entities: #{data.fetch('entity_mentions').length}",
        "Intents: #{intents.length}; blocked: #{blocked}; approvals: #{data.fetch('required_approvals').fetch('total')}",
        "Status: #{data.fetch('status')}"
      ].join("\n")
    end
  end
end
