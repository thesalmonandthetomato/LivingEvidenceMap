# Workflow 01 human-review postmortem — 2026-09-24

## Status

The corrected active human-decision file contains 132 rows for 132 unique review-case IDs:
- duplicate: 100
- not_duplicate: 32
- uncertain: 0

Twenty fabricated review-case IDs were identified in the conversational review of cases labelled 91–110. They were removed from the active decision and repair files and preserved in `data/adjudication/workflow01/run-35964195676/invalidated_review_entries.jsonl`.

## Failure mode

The error occurred in the human-review presentation layer, not in the source queue. Cases were presented from conversational reconstruction rather than being rendered directly from the immutable blinded queue artifact. Because no queue-membership check was run before each batch was committed, plausible but nonexistent review-case IDs could temporarily enter the active decision file.

The existing final validator, `workflow_01_validate_human_decisions.R`, rejects unknown review-case IDs and therefore would have blocked finalisation. The control was too late in the process.

## Abstract-error provenance

Among 16 unique records explicitly identified during human review as having a wrong/misaligned abstract and requiring stripping or replacement:
- Lens: 9 (56.3%)
- OpenAlex: 6 (37.5%)
- Scopus: 1 (6.3%)
- AGRICOLA: 0
- Europe PMC: 0

There were 21 repair occurrences because some corrupted source records appeared in more than one review pair. These figures describe ingestion provenance, not necessarily the upstream origin of the bad metadata. Some errors occur in more than one index, indicating likely shared upstream metadata contamination.

## Ancillary-record provenance

Using a strict definition based on explicit supplementary/data/image/table titles or DOI suffixes, the 132-case queue contained 19 unique ancillary records:
- Lens: 15 (78.9%)
- OpenAlex: 4 (21.1%)

Lens records were mainly publisher-level supplementary objects from Frontiers and PLOS (Data Sheet, Image, Table, AGI supplement/figure objects). OpenAlex records were mainly Figshare supplementary/data objects.

A broader classification that also includes repository datasets with non-obvious titles adds at least three OpenAlex records (University of Edinburgh dataset, PANGAEA dataset, USDA Ag Data Commons), giving at least 22 ancillary/data objects overall: Lens 15 and OpenAlex 7.

These counts are from the 132-case human-review queue and are not prevalence estimates for the full corpus.

## Required controls before fortnightly automation

1. Human-review batches must be generated mechanically from the queue file by R. The assistant must never reconstruct or invent review cases from conversational memory.
2. Every batch must carry a batch ID, queue SHA-256, ordinal range, review_case_id, pair_key, and immutable source_record_id for both records.
3. Decisions must be written through an R submission/validation step that checks the supplied case IDs are exactly the expected IDs for that batch before modifying the active decision file.
4. Run queue-membership validation after every batch, not only at finalisation. Unknown, missing, duplicated or out-of-batch IDs must fail immediately.
5. Keep an append-only decision-history file separate from a generated active-decision view containing exactly one effective decision per review_case_id.
6. Repair actions must target immutable source_record_id values rather than only record A/B. They must record old value, new value/action, review_case_id, queue hash, reviewer and timestamp.
7. Add a repair validator: the target source_record_id must be one of the two records in the referenced review case; canonical preferences must identify a member of that pair.
8. The auto-resume barrier must require: exact queue hash match; decision count = queue count; zero unknown IDs; zero duplicate active IDs; zero uncertain cases; all repair targets valid.
9. Tag obvious ancillary objects during normalisation. Publisher supplementary objects should remain as manifestations but should not become canonical records or proceed independently to relevance/topic coding.
10. Add source-data quality audits for repeated identical abstracts across bibliographically incompatible records. Flag for quarantine rather than automatically copying or trusting the abstract.
11. Preserve source-specific provenance for every field so a repaired abstract or title never loses its original source and correction history.
12. Fortnightly runs should be incremental and reuse locked historical adjudications; only newly created review_case_ids should enter the new human-review queue.
