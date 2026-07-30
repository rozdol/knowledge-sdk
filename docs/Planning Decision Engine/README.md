# Planning & Decision Engine

Phase 8 adds deterministic goal reasoning without changing the Knowledge Graph Engine, Extraction Pipeline, Intelligence Layer, or Agent Platform boundary. The graph still answers “what is true,” Intelligence answers “what is important,” and this layer answers “which constraint-feasible plan ranks best under the declared decision policy.”

## Responsibility split

```text
Goal + Constraints
        |
        v
Candidate Plan Generator
  - invokes one or more planners
  - performs deterministic graph search
  - emits alternatives, evidence, steps, and review-only Intent payloads
  - does not score or choose
        |
        v
Scenario Evaluator
  - simulates meetings, introductions, follow-ups, duration, budget, and travel
  - reads versioned Intelligence features
  - checks every hard constraint
  - emits benefits, risks, costs, confidence, and feature trace
  - does not choose
        |
        v
Decision Engine
  - applies one versioned shared policy
  - rejects hard-constraint violations
  - computes documented weighted components
  - exposes Pareto-optimal alternatives
  - uses stable plan IDs as the final tie-break
        |
        v
decision-approved Plan + ranked alternatives + trace
        |
        v
optional review-only Proposal -> explicit human approval -> existing Engine
```

The term `decision_approved` is intentionally narrower than proposal approval. It means “selected by the deterministic decision policy.” It never means “authorized to execute.” Every plan, step, Gateway response, and planning proposal declares `executable: false` until the existing proposal approval and Engine submission path is used.

## Models

`Goal` is immutable and contains an ID, description, goal type, priority, optional deadline, constraints, preferences, success criteria, and status. Goal files live only in `_System/KnowledgeGraph/Runtime/planning/goals/`, which is Git-ignored operational state rather than graph truth.

`ConstraintSet` supports:

- maximum introductions, meetings, duration, and budget;
- location, exact/start/end date, time, and language;
- travel allowed/forbidden;
- existing contacts only;
- no cold outreach;
- approval required.

Unknown constraint names and invalid types fail closed. Constraints compose by immutable merge. The evaluator checks them before the Decision Engine may mark any plan `decision_approved`.

`CandidatePlan` contains versioned planner identity, steps and dependencies, alternative plan IDs, effort, value, confidence, risk, graph evidence, required approvals, generated Intent payloads, and simulation metadata. Constructor validation uses the existing `IntentFactory` so a planner cannot attach an unknown Intent type.

`ScenarioEvaluation` contains benefits, risks, cost, expected outcome, feature values, deterministic simulation, confidence, and constraint violations. `DecisionResult` contains the ranked scenarios, Pareto frontier, selected plan, all score components, rules, and a machine-readable phase trace.

## Determinism

Stable IDs are SHA-256-derived from canonical structured inputs. Graph traversal sorts nodes and edges. Planners, features, evidence, scenarios, rules, scores, and final tie-breaks all use explicit stable ordering. No wall-clock value participates after the required `as_of` date is supplied. LLMs are not used to create, rank, or simulate plans; a client may summarize the already-computed result.

Determinism contract:

```text
same snapshot digest
+ same Goal planning signature
+ same constraints and preferences
+ same planner versions
+ same policy version
+ same as_of date
= byte-equivalent canonical DecisionResult
```

## Strategies and extension

The default library includes warm introduction, direct outreach, relationship maintenance/customer recovery, event/conference, project staffing/recruiting, travel, and an evidence-first generic baseline. Multiple planners may support the same goal. `CandidatePlanGenerator` invokes all matching planners and the same `DecisionEngine` evaluates every result, so a new planner cannot silently introduce its own selection policy.

A planner implements:

```ruby
plan(goal, graph_snapshot, constraint_set, context: planning_context)
```

It returns zero or more immutable `CandidatePlan` objects. It must not rank its output, write runtime state, mutate Markdown, call the Engine, or execute generated Intents.

## Shared decision policy

`config/planning_policies.yml` defines versioned weights, a human-readable rule for every score component, and Pareto objective directions. Current criteria cover goal relevance, preference alignment, relationship strength, trust, recency, evidence support, value, confidence, effort efficiency, and risk safety. Hard constraints are not weights: they reject a scenario before ranking.

The trace records raw value, weight, contribution, rule ID, and rule text for every component. It also explains why the first plan won and why other plans remained alternatives or were rejected.

## Proposal boundary

Planners may attach valid Intent payloads to steps, usually follow-up or meeting proposals. `KnowledgePlanning::ProposalAdapter` converts only the selected feasible plan into the existing immutable extraction-proposal shape. It retains exact graph evidence and planning confidence, sets every generated Intent to `human_review`, validates through the existing `ProposalValidator`, and can persist through the existing `ProposalStore`.

The adapter cannot approve or submit a proposal. Execution remains:

```text
planning proposal
  -> exact immutable human approval receipt
  -> ProposalSubmitter
  -> Engine#execute
```

## CLI

Create or manage operational goals:

```sh
ruby "_System/KnowledgeGraph/bin/kg" goal create \
  '{"description":"Reach a target","goal_type":"warm_introduction","constraints":{"no_cold_outreach":true},"preferences":{"target_ids":["person_<ULID>"]}}'
ruby "_System/KnowledgeGraph/bin/kg" goal list
ruby "_System/KnowledgeGraph/bin/kg" goal archive goal_<ULID>
```

Plan from a stored goal ID or inline JSON:

```sh
ruby "_System/KnowledgeGraph/bin/kg" plan goal goal_<ULID> --as-of 2026-07-30
ruby "_System/KnowledgeGraph/bin/kg" plan scenarios goal_<ULID> --as-of 2026-07-30
ruby "_System/KnowledgeGraph/bin/kg" plan compare goal_<ULID> --as-of 2026-07-30
ruby "_System/KnowledgeGraph/bin/kg" plan simulate goal_<ULID> --as-of 2026-07-30
ruby "_System/KnowledgeGraph/bin/kg" plan explain goal_<ULID> --as-of 2026-07-30
ruby "_System/KnowledgeGraph/bin/kg" plan trace goal_<ULID> --as-of 2026-07-30
ruby "_System/KnowledgeGraph/bin/kg" plan proposal goal_<ULID> --as-of 2026-07-30 --persist
```

## Gateway

Five policy-filtered contracts are available to Hermes and future clients:

- `kg.planning.plan`
- `kg.planning.compare`
- `kg.planning.simulate`
- `kg.planning.explain`
- `kg.planning.create_proposal`

The four reasoning capabilities are read-only. Proposal creation has `proposal_write` effects, requires `planning:read` and `proposal:create`, and still returns `executable: false`. Public serialization drops storage paths and filters entire plans whose entity or evidence records are restricted under the calling agent's permissions.

## Verification

The Phase 8 suite covers goals, constraints, planner separation, multi-planner comparison, graph search, ranking, Pareto alternatives, simulation, proposal validation, CLI/Gateway integration, graph non-mutation, deterministic replay, and eight synthetic golden scenarios: conference, sales, fundraising, recruiting, customer recovery, warm introduction, project launch, and travel.

```sh
ruby -I"_System/KnowledgeGraph/lib" -I"_System/KnowledgeGraph/test" \
  -e 'Dir["_System/KnowledgeGraph/test/planning/**/*_test.rb"].sort.each { |f| require File.expand_path(f) }'
ruby -I"_System/KnowledgeGraph/lib" -I"_System/KnowledgeGraph/test" \
  -e 'Dir["_System/KnowledgeGraph/test/**/*_test.rb"].sort.each { |f| require File.expand_path(f) }'
ruby "_System/Tools/validate_vault.rb"
```
