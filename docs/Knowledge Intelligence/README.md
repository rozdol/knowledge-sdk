# Knowledge Intelligence Layer

Knowledge Intelligence is a deterministic, read-only reasoning layer over the canonical Markdown graph. It creates derived observations, explanations, recommendations, briefings, reports, and optional reviewable Intent proposals. It never edits Markdown, serializes canonical YAML, executes Intents, or treats a derived value as a fact.

## Architecture

```text
Canonical Markdown
        │ read once
        ▼
Immutable GraphSnapshot ───────────────┐
        │                              │ evidence records
        ▼                              │
FeatureEngine                          │
  ├─ versioned FeatureRegistry         │
  ├─ dependency resolution             │
  ├─ per-run memoization               │
  └─ graph projections/algorithms      │
        │                              │
        ▼                              │
Independent Analyzers ◄────────────────┘
        │ AnalysisResult / Finding
        ├─ explanation
        ├─ confidence
        ├─ evidence
        ├─ graph path
        └─ optional IntentProposal
        │
        ▼
RuleEngine → Recommendations → Reports / Digest / Query / Briefing
                                      │
                                      └─ optional proposal JSON
                                          → existing approval system
                                          → existing Engine
```

`GraphSnapshot` deep-copies and freezes canonical frontmatter, resolves structural wiki links, and records a SHA-256 digest. An analysis verifies that the digest did not change. Bodies are not promoted to facts and are not inputs to deterministic reasoning.

`FeatureEngine` is the single implementation point for reusable derived features. A cache key includes snapshot, feature name and version, entity arguments, parameters, and `as_of`. The cache exists only in memory for one engine run. No cached feature is written to a canonical note.

Analyzers depend on feature names, not on each other's implementations. Analyzer dependencies are declared only when orchestration is required; for example, the recommendation analyzer consumes prior findings. Adding an analyzer means registering another object, without editing existing analyzers.

## Determinism and time

All date-sensitive operations require an explicit `as_of` value internally. CLI defaults to the local current date and supports `--as-of YYYY-MM-DD` for reproducible runs. Sorted traversal, stable base32 IDs, deterministic community labels, and canonical serialization make output identical for the same snapshot, configuration, and date.

`execution_time_ms` is `0` in deterministic output. `--profile` opts into measured wall-clock runtime and therefore intentionally makes that metadata non-deterministic.

## Feature reference

Every feature returns its name, semantic version, scope, value, evidence, explanation, and calculation metadata.

| Feature | Scope | Version | Definition |
|---|---|---:|---|
| `recency_score` | entity pair; Self default | 1.0.0 | Exponential decay from the latest substantive interaction. Default half-life: 90 days. |
| `interaction_frequency` | entity pair; Self default | 1.0.0 | `1 - exp(-weighted_count / 6)` over 365 days; substantive `1.0`, incidental `0.25`, mass `0.05`. |
| `trust_score` | entity | 1.0.0 | 70% relationship assertion confidence, 20% source coverage, 10% human attribution; neutral prior `0.5`. |
| `relationship_strength` | entity pair; Self default | 1.0.0 | 35% recency, 25% frequency, 20% asserted closeness, 10% trust, 10% connector activity. |
| `graph_distance` | entity pair | 1.0.0 | Unweighted shortest path in the social projection; `null` when disconnected. |
| `influence_score` | entity | 1.0.0 | 45% degree centrality, 35% betweenness, 20% completed-introduction activity. |
| `completeness_score` | entity | 1.0.0 | Fraction of documented, type-specific profile signals; missing signals stay derived. |
| `community_membership` | entity | 1.0.0 | Deterministic label propagation, canonically labeled by the smallest member ID. |

Feature definitions are immutable after registry construction. Changing a formula requires a version bump. An analyzer may compose features, but only the canonical snapshot remains the source input; memoized values are disposable execution artifacts.

## Graph algorithms and scale

The standard-library implementation includes BFS, DFS, shortest path, connected components, Tarjan bridge detection, degree centrality, Brandes betweenness, and deterministic label propagation.

Linear algorithms operate in `O(V + E)`. Betweenness is exact for small graphs and uses up to 128 evenly spaced, deterministic source nodes for large graphs. This bounds work without changing output between runs. Synthetic performance tests use 5,000 nodes and 25,000 edges by default; set `KI_FULL_PERFORMANCE=1` to exercise 100,000 nodes and 1,000,000 edges.

## Analyzers

The default registry contains:

- Relationship, Opportunity, Knowledge Gap, Follow-up, Activity, Project, Timeline, Network, and Memory analyzers.
- Anomaly and Consistency analyzers for contradictory preferences, relationship duplication, primary-residence cardinality, and broken structural links.
- Recommendation analyzer, which applies safe declarative rules from `config/intelligence_rules.yml` to source findings.

Every analyzer returns `AnalysisResult` with analyzer name, version, deterministic execution-time field, findings, and metrics. Every finding includes a stable ID, confidence, evidence references, human explanation, machine details, severity, priority, tags, optional graph path, and optional proposals.

## Rules and recommendations

Recommendations are not hardcoded inside source analyzers. YAML configuration may match finding kinds and minimum confidence, then declare recommendation kind, title, severity, priority, tags, and explanation template. The loader accepts data only; it does not evaluate Ruby or arbitrary expressions.

Default rules cover reconnecting valuable inactive contacts, completing contact profiles, resolving follow-ups, repairing commitments, considering introductions, reviewing stale projects, and investigating data-quality anomalies.

## Intent proposals and approval

An analyzer may attach a `KnowledgeGraph::IntentFactory`-compatible payload. It remains non-executable inside the finding. `ProposalAdapter` converts selected findings to the existing extraction proposal schema and validates them with the existing `ProposalValidator`.

`kg intelligence proposal` prints the immutable JSON only. `--persist` is an explicit request to store proposal JSON under the existing runtime proposal directory. It does not approve or submit anything. The existing `kg proposal approve` and `kg proposal submit` commands remain the only path from review to Engine execution, and Engine gates remain authoritative.

## CLI examples

```sh
kg intelligence relationships --as-of 2026-07-29
kg intelligence opportunities --format markdown
kg intelligence memory --person "Ada" --as-of 2026-07-29
kg intelligence digest --period weekly
kg intelligence digest --period daily
kg intelligence report personal_crm
kg intelligence features --person "Ada"
kg intelligence query "Who have I ignored the longest?"
kg intelligence explain finding_<ID>
kg intelligence proposal finding_<ID>
```

Analyzer commands are `relationships`, `opportunities`, `gaps`, `followups`, `activity`, `timeline`, `network`, `projects`, `memory`, `recommendations`, `anomalies`, `consistency`, and `all`.

Reports are `relationship_health`, `knowledge_gap`, `opportunity`, `network`, `followup`, `project`, `daily_digest`, `weekly_digest`, `monthly_digest`, and `personal_crm`.

The deterministic natural-query surface intentionally supports a bounded grammar rather than LLM interpretation. English and Russian forms are available for people connected to a concept, introducers, longest-ignored contacts, connected companies, and projects involving an entity. Unsupported wording fails explicitly.

## Tests

```sh
ruby -I"test" -e 'Dir["test/intelligence/*_test.rb"].sort.each { |file| require File.expand_path(file) }'
```

The suite contains unit, cross-layer integration, CLI read-only, golden-scenario, determinism, proposal-validation, and performance coverage. All fixtures are synthetic. The golden corpus covers forgotten contacts, bridge people, missing email, investor paths, broken promises, inactive relationships, stale projects, multiple introductions, network bottlenecks, and duplicate candidates.
