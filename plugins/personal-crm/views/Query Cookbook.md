# Query Cookbook

These examples query canonical Markdown. For large-vault multi-hop analysis, use the disposable-index scale gate described in the data model.

## Who lives in London?

```dataview
TABLE WITHOUT ID subject AS "Person", valid_from AS "Since"
FROM "Relationships/lives_in"
WHERE type = "relationship"
  AND relationship_status = "asserted"
  AND object = [[Places/Cities/London]]
  AND (!valid_to OR date(valid_to) >= date(today))
```

## Who likes skiing?

```dataview
TABLE WITHOUT ID subject AS "Person", strength AS "Strength"
FROM "Relationships/likes"
WHERE type = "relationship"
  AND relationship_status = "asserted"
  AND object = [[Concepts/Interests/Skiing]]
```

## Open promises made by Self

```dataview
TABLE WITHOUT ID promise_to AS "To", action AS "Promise", due_on AS "Due"
FROM "Commitments/Promises"
WHERE type = "commitment"
  AND commitment_status = "open"
  AND promisor = [[People/Self]]
SORT due_on ASC
```

## Who introduced Self and John?

```dataview
TABLE WITHOUT ID introducer AS "Introducer", occurred_on AS "Date", file.link AS "Record"
FROM "Interactions/Introductions"
WHERE type = "introduction"
  AND assertion_status = "asserted"
  AND (person_a = [[People/Self]] OR person_b = [[People/Self]])
  AND (person_a = [[People/John Smith]] OR person_b = [[People/John Smith]])
```

## Which people work for Microsoft?

```dataview
TABLE WITHOUT ID subject AS "Person", role AS "Role", literal_title AS "Title"
FROM "Relationships/works_for"
WHERE type = "relationship"
  AND relationship_status = "asserted"
  AND object = [[Organizations/Microsoft]]
  AND (!valid_to OR date(valid_to) >= date(today))
```

## Validation

Run from the vault root:

```text
kg validate
```
