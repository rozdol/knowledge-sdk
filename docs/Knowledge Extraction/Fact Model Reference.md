# Fact Model Reference

`EntityMention` represents pre-canonical identity with display spelling, aliases, email, phone, external IDs, organization/role context, and evidence. `ScalarValue` retains raw and normalized values plus normalization confidence. `ExtractedFact` links a subject mention to an entity or scalar object without depending on Engine Intents.

Supported fact families are entity existence, attributes, relationships, interactions, meetings, promises, follow-ups, and corrections. Statuses are `asserted`, `negated`, `uncertain`, `corrected`, `superseded`, `planned`, and `historical`.

Confidence bands are configurable; defaults plan nothing below 0.40. Suggested interpretation is 0.95–1.00 explicit, 0.80–0.94 strongly supported, 0.60–0.79 reviewable, 0.40–0.59 weak, and below 0.40 unplannable. Fact, entity-resolution, and planning confidence remain separate. A high fact score cannot compensate for ambiguous identity.

Negation, speculation, corrections, and future intent remain review facts but do not create graph Intents. Historical relationships need an explicit end date before execution planning.
