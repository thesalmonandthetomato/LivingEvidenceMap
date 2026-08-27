# Updater Pipeline — Workflow 01: Lens ingestion

**Status:** LOCKED — architecture and tested prototype implementation
**Scope:** Lens API ingestion only
**Last reviewed:** 2026-08-27

## Purpose

Retrieve Lens Scholarly search results without loss of Lens metadata, preserve the raw API responses, and emit canonical JSONL records for the downstream processing pipeline.

This workflow does **not** perform deduplication, screening, annotation, adjudication, topic modelling, master-CSV construction, or dashboard updates.

## Locked architecture

- Full Lens records are requested; the restrictive legacy `include` list is not used.
- Raw Lens API responses are retained as immutable JSON batch artefacts.
- Canonical processing format is JSONL: one evidence record per physical line.
- `lens_id` is the authoritative evidence-record identifier; DOI is secondary and title is not an identity fallback.
- The complete Lens record is retained inside each canonical record under `lens.raw_payload`.
- Run-level provenance is kept in the manifest; record-level provenance is kept in each canonical record.
- CSV is not used as an intermediate processing format.
- RIS is a separate future adapter: `RIS -> canonical JSONL`.
- Weekly successful-search state must advance only after complete successful ingestion.
- Retrieval must be restartable and idempotent.

## Tested implementation

The isolated implementation is `scripts/updater/lens_ingestion.py` on branch `updater-workflow-01-lens-ingestion` and is exercised by the manual test workflow on `main`.

The implementation has been tested against a six-month Lens window with unrestricted records and multi-page retrieval. The successful test demonstrated:

- 766 Lens records reported;
- 766 records retrieved;
- 8 API batches;
- 766 unique `lens_id`s;
- 0 records without `lens_id`;
- 766 independently parseable canonical JSONL records;
- successful handling of the previously identified Unicode line-separator JSONL issue;
- successful checkpoint/failure/restart test with recovery after an intentional mid-run failure.

The tested output preserves the rich Lens payload, including nested bibliographic and metadata structures, rather than flattening it prematurely.

## Execution boundary

```text
Lens API
  |
  +--> immutable raw response batches
  |
  +--> canonical JSONL
          |
          v
       Workflow 02: deduplication
```

## Artefact requirements

Each run must retain, at minimum:

- raw Lens response batches;
- canonical JSONL increment;
- run manifest;
- retrieval checkpoint state;
- successful-search checkpoint only after full success;
- search-history information.

The test workflow retains these as GitHub Actions artefacts. Production implementation must retain equivalent artefacts in the repository's durable pipeline storage.

## Manifest requirements

The run manifest must distinguish:

- run ID;
- search window;
- search configuration/version or hash;
- Lens-reported search total;
- API batches requested/completed;
- raw records received;
- valid `lens_id` records;
- within-run duplicates;
- canonical records emitted;
- page size/pagination method;
- retries/failures;
- artefact references/checksums where practical;
- final status.

The Lens search-result total and actual ingested-record count are distinct provenance quantities.

## Failure/restart contract

A partial run must not advance the successful-search checkpoint. Completed retrieval batches must remain available as checkpoints, and a restart must be able to resume from the last successful retrieval checkpoint without silently losing or duplicating records.

Transient HTTP 429, 5xx, and network/time-out errors must be retried according to the implementation's retry policy. Persistent failure must leave the run distinguishable as incomplete/failed.

## Downstream contract

Workflow 02 may assume that Workflow 01 provides:

1. lossless Lens source data;
2. stable `lens_id` identity;
3. one canonical JSONL record per retrieved evidence record;
4. run-level and record-level provenance;
5. clear success/failure state;
6. resumable artefacts/checkpoints;
7. no downstream screening, annotation, adjudication, topic modelling, or dashboard-specific flattening.

Workflow 02 must not need to reconstruct discarded Lens fields.

## Legacy migration

The current master contains 13,389 records. Historical reconstruction is separate from new ingestion. Where archived evidence establishes historical decisions, it may be incorporated into the canonical record; where it cannot establish a decision, the historical value remains unknown/blank rather than being inferred.

## Change control

This workflow is now **locked for the next pipeline stage**. Changes to its input/output contract or identity/provenance rules require explicit approval. Downstream work should consume the locked contract rather than modifying Workflow 01 implicitly.

The existing production weekly updater remains separate until the complete replacement pipeline has been built and validated.
