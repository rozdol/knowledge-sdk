# CRM Dashboard

## Due and overdue follow-ups

```dataview
TABLE WITHOUT ID
  file.link AS "Follow-up",
  due_on AS "Due",
  priority AS "Priority",
  with AS "With"
FROM "Commitments/Follow-ups"
WHERE type = "follow-up"
  AND record_status = "active"
  AND (followup_status = "open"
    OR followup_status = "scheduled"
    OR followup_status = "waiting"
    OR followup_status = "snoozed")
SORT due_on ASC, priority DESC
```

## Open promises

```dataview
TABLE WITHOUT ID
  file.link AS "Promise",
  promise_to AS "To",
  due_on AS "Due",
  priority AS "Priority"
FROM "Commitments/Promises"
WHERE type = "commitment"
  AND record_status = "active"
  AND commitment_status = "open"
SORT due_on ASC
```

## Contacts past cadence

```dataviewjs
const now = dv.date("today");
const people = dv.pages('"People"')
  .where(p => p.type === "person"
    && p.record_status === "active"
    && p.is_self !== true
    && p.life_status !== "deceased"
    && p.contact_policy !== "do_not_contact"
    && p.tier !== "archive");

const interactions = dv.pages('"Interactions"')
  .where(i => i.type === "interaction"
    && i.record_status === "active"
    && i.contact_weight === "substantive");

const rows = [];
for (const person of people) {
  const contactDates = interactions
    .where(i => (i.participants ?? []).some(link => link.path === person.file.path))
    .map(i => dv.date(i.starts_at))
    .where(Boolean)
    .array()
    .sort((a, b) => b.toMillis() - a.toMillis());

  const last = contactDates[0] ?? null;
  const cadence = Number(person.cadence_target_days ?? 180);
  const due = last ? last.plus({ days: cadence }) : null;
  if (!due || due < now) {
    rows.push([
      person.file.link,
      person.tier,
      last ?? "Never",
      cadence,
      due ?? "Now"
    ]);
  }
}

rows.sort((a, b) => {
  if (a[2] === "Never") return -1;
  if (b[2] === "Never") return 1;
  return a[2].toMillis() - b[2].toMillis();
});

dv.table(["Person", "Tier", "Last substantive contact", "Cadence days", "Due"], rows);
```

## Upcoming events

```dataview
TABLE WITHOUT ID
  file.link AS "Event",
  starts_at AS "Starts",
  place AS "Place"
FROM "Interactions/Events"
WHERE type = "event"
  AND record_status = "active"
  AND starts_at >= date(today)
SORT starts_at ASC
LIMIT 20
```

## Relationship counts

```dataview
TABLE WITHOUT ID
  predicate AS "Predicate",
  length(rows) AS "Count"
FROM "Relationships"
WHERE type = "relationship"
  AND record_status = "active"
  AND relationship_status = "asserted"
GROUP BY predicate
SORT length(rows) DESC
```
