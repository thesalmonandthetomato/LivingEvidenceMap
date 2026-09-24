# Workflow 01 abstract-mismatch stripping

Workflow 01 is deduplication. It does not repair or refill abstracts and it does not rerun deduplication after an abstract is stripped.

When duplicate adjudication identifies that a record's abstract is semantically inconsistent with its own title:

1. Complete the duplicate/not-duplicate adjudication.
2. Record an `abstract_strip_actions.jsonl` action keyed by immutable `source` + `source_record_id`.
3. Preserve the original abstract and the review-case/pair provenance in that audit action.
4. The downstream corpus materialisation step applies the strip, so the affected record enters the post-dedup corpus with a missing abstract.
5. Workflow 03 discovers that record through its normal missing-title/missing-abstract scan. Records with a DOI are therefore automatically eligible for the existing DOI-based abstract repair logic.
6. Workflow 01 does not create a special Workflow 03 repair queue.

The paired record's abstract must never be copied across as a replacement merely because both records originally shared it.
