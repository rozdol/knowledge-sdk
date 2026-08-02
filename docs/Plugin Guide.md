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

Trusted SDK code plugins can add a domain without changing `kg chat` by registering a deterministic matcher on the shared classifier. The fixed route priority is `dataset`, `analyze`, `observe`, `search`, `plan`, then `proposal`.

```ruby
KnowledgeSDK.intent_classifier.register(name: "nutrition-observations", route: "dataset") do |text, context|
  next unless text.match?(/\bprotein\b/i)

  {
    "intent" => "dataset.nutrition",
    "confidence" => 0.93,
    "reason" => "recognized a structured nutrition observation",
    "slots" => { "captured_at" => context["captured_at"] }
  }
end
```

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
