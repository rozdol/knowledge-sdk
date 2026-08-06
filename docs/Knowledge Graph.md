# Knowledge Graph boundary

The Knowledge Graph stores typed entities and relationships selected by an installed Vault ontology.
Capture and Dataset are adjacent first-class knowledge types, not alternate graph facts.

```text
Graph: typed Markdown entities and canonical relationships
Capture: SDK-owned Markdown inbox records with immutable content
Dataset: typed structured rows in SQLite plus a graph registry note
Evidence: immutable local source rendition and bounded provenance
```

Every canonical write still reaches `KnowledgeGraph::Engine`. Graph Intents use schema and predicate
registries. Capture Intents use the SDK-owned Capture validator and never add a `capture` schema to an
attached Vault. Dataset Intents delegate from the Engine boundary to the Structured Dataset Engine.

`graph.observe` is not a fallback. It recognizes explicit supported graph-fact shapes only. An
explicit personal note routes to Capture; a measurement routes to Dataset; a lookup routes to Search;
unknown text clarifies. Approved Capture links store canonical target IDs on the Capture but never
modify the target or create a graph relationship. Promotion may later propose an ordinary graph
Intent, and that target must independently satisfy the installed ontology and Engine validation.

Graph snapshots exclude Captures by design. Cross-knowledge search and analysis combine graph
evidence with Capture evidence at the read layer, preserving their storage and authority boundaries.
