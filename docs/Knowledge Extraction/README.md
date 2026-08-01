# Knowledge Extraction Pipeline

Phase 5 converts unstructured information into immutable, reviewable Knowledge Graph proposals. It does not write canonical Markdown, construct YAML, or execute proposed Intents automatically. Ruby standard-library code keeps ordinary tests offline and vendor-neutral.

## Boundary

```text
source text -> normalization -> structured extraction -> validation
            -> conservative resolution -> Intent planning -> proposal review
            -> explicit approval -> Knowledge Graph Engine -> canonical vault
```

`KnowledgeGraph::GraphReader` is the pipeline's narrow read-only graph interface. `KnowledgeGraph::Engine#execute` remains the only graph write path. Proposal, approval, source-deduplication, and submission receipts live under ignored local Runtime storage and are not canonical facts.

## Quick start

```sh
kg extract text --file note.txt --captured-at 2026-07-29T12:00:00+03:00 --dry-run
kg extract transcript --file meeting.txt
kg proposal show proposal_<ULID>
kg proposal validate proposal_<ULID>
kg --actor-id human:alex proposal approve proposal_<ULID> --all
kg proposal submit proposal_<ULID> --dry-run
```

## Ruby API

```ruby
reader = KnowledgeGraph::GraphReader.new(vault_root: Dir.pwd)
configuration = KnowledgeExtraction::Configuration.new(
  provider_name: "replay",
  allowed_entity_types: reader.entity_types,
  allowed_predicates: reader.predicates
)
pipeline = KnowledgeExtraction::KnowledgeExtractionPipeline.new(
  graph_reader: reader,
  provider: KnowledgeExtraction::ReplayExtractionProvider.new("fixture.json"),
  configuration: configuration
)
proposal = pipeline.process(
  "Alice Carter works at Northstar.",
  source_type: "text",
  language: "en",
  captured_at: "2026-07-29T12:00:00+03:00"
)
```

The explicit stages are `normalize`, `extract`, `validate_facts`, `resolve_entities`, and `plan_intents`. Every intermediate artifact has `to_h`/JSON serialization.

## Known limitations

The local deterministic provider intentionally recognizes only a narrow set of English patterns; production semantic coverage requires a schema-constrained configured provider. Speech recognition, OCR, PDF parsing/rendering, connectors, web UI, REST ingestion, and background automation remain adapter extension points. Ternary introductions and promise roles remain blocked unless a provider supplies complete canonical structural roles. Submission uses explicit dependency-ordered Engine transactions because Phase 4 has no public whole-proposal transaction API.

## English example

“Alice Carter works at Northstar” yields two entity mentions, an asserted `works_for` fact with exact offsets, conservative resolution decisions, dependent `CreateEntity`/`AddRelationship` Intents, risk labels, and approval requirements. No canonical note changes before proposal submission.

## Russian example

“Анна Волкова работает в компании Север” preserves Russian spelling and evidence. The replay output uses canonical `works_for` internally without translating either entity name. “не работала” remains a negated fact and produces no executable Intent.

## Guides

- [Architecture Guide](Architecture%20Guide.md)
- [Source Adapter Guide](Source%20Adapter%20Guide.md)
- [Fact Model Reference](Fact%20Model%20Reference.md)
- [Evidence and Provenance Guide](Evidence%20and%20Provenance%20Guide.md)
- [Entity Resolution Guide](Entity%20Resolution%20Guide.md)
- [Intent Planning Guide](Intent%20Planning%20Guide.md)
- [Approval Integration Guide](Approval%20Integration%20Guide.md)
- [LLM Provider Adapter Guide](LLM%20Provider%20Adapter%20Guide.md)
- [Evaluation Framework Guide](Evaluation%20Framework%20Guide.md)
- [Privacy and Security Guide](Privacy%20and%20Security%20Guide.md)
- [CLI Reference](CLI%20Reference.md)
