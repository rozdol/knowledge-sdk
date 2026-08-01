---
predicate: recommended
direction: directed
symmetric: false
subject_types: [person, organization]
object_types: [person, organization, place, project, book, interest, technology, event]
inverse: recommended_by
allowed_fields: [recipient, recipient_id, strength]
required_fields: [recipient, recipient_id]
---
# recommended

Recommendation from subject to recipient about object.
