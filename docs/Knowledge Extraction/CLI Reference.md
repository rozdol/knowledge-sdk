# Knowledge Extraction CLI Reference

Global options remain `--vault`, `--run-id`, and `--actor-id` and must appear before the command.

## Extraction

```text
kg extract text|chat|meeting-notes|email-text|transcript|ocr-text|pdf-text --file PATH
  [--language CODE] [--captured-at ISO8601] [--external-id ID]
  [--source-uri URI] [--title TITLE] [--provider deterministic|replay]
  [--format summary|json|markdown] [--dry-run]

kg extract replay --fixture FIXTURE.json [--dry-run]
kg extract evaluate --provider replay [--dataset cases.json]
```

Dry-run never persists a proposal and never calls the Engine. Non-dry extraction persists only an ignored Runtime proposal, not canonical graph data.

## Review and execution

```text
kg proposal show PROPOSAL_ID
kg proposal export PROPOSAL_ID --format json|markdown
kg proposal validate PROPOSAL_ID
kg proposal approve PROPOSAL_ID --intent PLANNED_INTENT_ID --actor HUMAN_ID
kg proposal approve PROPOSAL_ID --all --actor HUMAN_ID
kg proposal submit PROPOSAL_ID [--dry-run]
```

Approval and submission are distinct. `submit --dry-run` reports readiness without execution. Actual submission returns per-Intent `executed`, `blocked`, or `failed` states plus audit/replay metadata.
