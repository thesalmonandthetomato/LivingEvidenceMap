# Workflow 01 abstract-mismatch handoff

Workflow 01 is the deduplication stage. It must not rerun deduplication after metadata repair.

When the duplicate-adjudication model identifies that an abstract is semantically inconsistent with one record's own title, Workflow 01 should:

1. Finish the duplicate/not-duplicate adjudication for the pair.
2. Mark the affected source record by immutable `source` + `source_record_id`.
3. Strip the incorrect abstract from that record in the post-deduplication metadata output.
4. Add that record automatically to the abstract-repair handoff queue for Workflow 03.
5. Preserve the original bad abstract and mismatch provenance in the audit trail.
6. Continue downstream from the completed Workflow 01 deduplication state. Do not rerun candidate generation, duplicate scoring, adjudication or clustering because of the abstract repair.

Workflow 03 owns abstract repair/refill. It should seek a verified replacement abstract for the exact record, preferably by DOI and otherwise by a strong title + author + year match. If no verified replacement exists, the abstract remains missing.

The paired record's abstract must never be copied across solely because it matched the contaminated abstract.
