# Typed laboratory reads

Dashboard P5 registers `kg.health.labs` and `kg.health.lab_series` version 1.0.0
through the ordinary Agent Gateway. Both require `health:read`, `dataset:read`
and `graph:read`, are synchronous/read_only, require no approval and grant no
execution authority. The conversational Health routes and write templates are
unchanged. No Health installation or storage provisioning happens during a read.

`labs(scopes: true)` accepts no other arguments and returns `subjects: [{id,name}]`.
Subjects come only from explicit Dataset `owner_id` or row `subject_id`; they must
be active, visible Person identities. An owned empty Dataset can supply its subject.
Ordinary requests require `subject_id`; series also requires an exact `analyte`.
No current-user, filename, folder or inferred household scope is used. Missing and
hidden subjects have identical not-found behavior. Unrelated subjects are refused.
An unowned table with unscoped visible rows reports `subject_scope_unknown`;
conflicting row and Dataset subjects report `subject_scope_conflict`.

Both reads accept exact panel/analyte and inclusive date-only `from`/`to`, together,
ordered and at most 366 days apart. The default is 30 dates through today; HTTP
resolves today once in the configured display zone, direct Gateway calls use UTC.
Original `test_date` stays a date. Legacy `observed_at` retains its stored offset;
its recorded date component supplies the compatibility date without zone shifting.
The laboratory list uses descending test date, observation time, Dataset ID and
logical row ID, with visible-first keyset pages of 1–100 rows (default 25).

## Read compatibility

Recognition is SDK-owned and does not execute Vault schema content. Registrations
must identify the trusted `blood_tests` template with its exact installed version
and digest, or use the legacy `blood_tests` slug without template metadata. Present
but incomplete/unknown template metadata is refused. Physical columns must be a
subset of the installed template's columns with their declared types, plus optional
TEXT `subject_id`, `sensitivity` and `method`. The supported value read variants are
REAL, INTEGER and TEXT. The required semantic pairs are DATE `test_date` + TEXT
`analyte`, or legacy DATETIME `observed_at` + TEXT `marker`, with a `value` column.
Unknown columns/types/custom schemas are unsupported. These are explicit read
compatibility layouts, not new write templates or an automatic migration.

The existing numeric blood-test template remains unchanged. Already-recorded
qualitative TEXT values such as `Negative`, `<5` or `123` are returned verbatim;
TEXT is never parsed as numeric. The read API cannot import these values into an
incompatible numeric write schema. That requires a separately approved lifecycle
workflow, outside Dashboard P5.

## Privacy, bounds and clinical context

Dataset, row and subject visibility is checked before filtering, series grouping,
pagination or versions. Restricted clinical inclusion requires both
`graph:restricted` and `dataset:restricted`; a single grant is insufficient.
Hidden/missing referenced graph identities exclude the record. Opaque Evidence IDs
belong to the authorized row/Dataset and are never dereferenced. No source URI,
filename, span, comments, approval payload or attachment bytes are exposed.

Rows preserve panel, arbitrary analyte, original value/unit, original reference
low/high/text, flag, specimen, laboratory, method and permitted Evidence references.
Series groups by subject/analyte/unit/method/specimen/laboratory. Null metadata stays
unknown and separate from known metadata. No unit conversion, invented interval,
clinical diagnosis or treatment recommendation is performed. Per-point reference
intervals remain in the table; the plot uses only actual numeric results and
recorded interval pairs. Text results have no plotted point.

One nonmigrating Reader transaction loads existing rows, with a combined source
ceiling of 100,000 rows across at most 50 registrations. Exceeding either ceiling
is unavailable, rather than a truncated clinical input. Scope lists cap at 1,000
subjects. Output series cap at ten groups and 1,000 raw observations per group,
with `aggregation: none`, explicit `bounded` and partial limitation codes; refine
filters to inspect more. No silent downsampling occurs. Oversized source strings
(over 1,000 characters) are unavailable rather than silently shortened. Host time
and 1 MiB response limits still apply. Source versions depend on permitted results;
hidden-only changes do not change pages or versions.

The browser offers explicit subject selection, exact filters, the original table,
a dated timeline of the current page, and separate raw-point charts with table
alternatives. Series filters apply only to trends. Each source can fail/retry
independently. Filter/navigation/logout changes cancel obsolete reads and clear
private results. Diagnosis management, OCR/upload, clinical mutation and external
fetching are unavailable.
