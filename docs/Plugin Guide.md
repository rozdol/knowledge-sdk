# Plugin Guide

Plugins extend the SDK without changing core dispatch and without silently rewriting Vaults. A distribution plugin may contribute schemas, predicate definitions, templates, views, dataset adapters, planners, analyzers, validators, and public Gateway manifests.

```text
plugins/example/
  plugin.yml
  schemas/
  relationship_types/
  templates/
  views/
```

`plugin.yml` contains declarative paths. The SDK never executes Ruby paths supplied by a Vault or by ingested content. Trusted code plugins are installed with the SDK and register handlers explicitly through the existing `AgentPlatform::PluginRegistrar` boundary.

`kg plugin list` discovers installed SDK plugins. `kg --vault PATH plugin install NAME` is explicit and fail-closed: it refuses to replace an existing Vault file. `kg attach` may record or auto-detect a compatible profile, but attachment itself never installs plugin assets.

The bundled `personal-crm` plugin packages the current ontology, templates, views, and validator as an optional profile. Other Vaults may stay generic or use independently developed profiles; they do not need to copy this folder layout.

## Intent Classifier extensions

Trusted SDK code plugins can add an intent recognizer without changing `kg chat` by registering a deterministic matcher for one semantic domain. The classifier first selects `health`, `finance`, `crm`, `trading`, `knowledge`, or `generic`, invokes all plugins for the winning domain, and selects their highest-confidence result. Only when no winning-domain plugin matches does it evaluate generic analysis, planning, proposal, Dataset-table, and search plugins. The generic graph classifier is an explicit last-resort plugin, not the default route.

```ruby
KnowledgeSDK.intent_classifier.register(
  name: "nutrition-observations", domain: "health", route: "dataset"
) do |text, context|
  next unless text.match?(/\bprotein\b/i)

  {
    "intent" => "dataset.nutrition",
    "confidence" => 0.93,
    "explanation" => "recognized a structured nutrition observation",
    "slots" => { "captured_at" => context["captured_at"] }
  }
end
```

The `domain` registration field is required for specialized plugins. Omitting it retains compatibility by registering the matcher in `generic`; it does not make the matcher a graph fallback. Fallback classifiers are SDK-owned, explicitly registered with `fallback: true`, and restricted to the generic domain.

The shared classifier normalizes input as UTF-8 NFC before domain and intent matching. `classify_with_trace` returns the selected immutable classification plus safe diagnostics used by `kg chat --explain`; plugins still receive normalized original spelling rather than lowercased match text. Diagnostics contain only strings, confidence values, and plugin registration names.

The plugin must also register an SDK-owned immutable Dataset Intent/proposal mapping and an Engine handler that delegates to the Structured Dataset Engine. Classifier registration does not grant approval or execution authority. Matchers and handlers may come only from trusted installed SDK code, never from an attached Vault or imported content.

```ruby
StructuredDataset.routing_registry.register(
  intent: "dataset.nutrition",
  dataset: "nutrition",
  intent_class: MyPlugin::InsertNutritionMeasurement,
  builder: ->(common, slots) { MyPlugin::InsertNutritionMeasurement.new(**common.merge(slots)) },
  writer: ->(dataset_engine, intent, provenance) {
    dataset_engine.insert("nutrition", intent.values, provenance)
  }
)
```

The routing registry adds the immutable Intent class to the existing `IntentFactory`, proposal validation, and Proposal Submitter/Engine path. The writer is called only by the approval-gated SDK Dataset handler.

## Analysis plugins

Trusted installed code can add domain analysis without changing `kg analyze`. Register one object with a stable name, deterministic `supports?`, and deterministic `analyze` implementation:

```ruby
class TravelAnalysis
  def name
    "travel"
  end

  def supports?(question, _context)
    question.match?(/\b(?:trip|travel|vacation)\b/i)
  end

  def contributions
    {
      "analyzers" => ["travel_change"],
      "correlation_rules" => ["before_after_trip"],
      "dataset_interpreters" => ["travel", "expenses", "sleep"],
      "recommendation_generators" => ["travel_review"],
      "explanation_templates" => ["changes_after_trip"]
    }
  end

  def analyze(context)
    # Return a deterministic fragment using context.series,
    # context.correlations, graph evidence, Activity, and limitations.
  end
end

KnowledgeAnalysis.registry.register(TravelAnalysis.new)
```

The SDK merges fragments, sorts factors by confidence and stable ID, and renders the existing human/JSON contract. Plugins do not receive an Engine, cannot approve or execute recommendations, and must label correlations as noncausal. Executable plugin code comes only from installed SDK resources; attached-Vault content and imported rows cannot register analyzers or rules.
