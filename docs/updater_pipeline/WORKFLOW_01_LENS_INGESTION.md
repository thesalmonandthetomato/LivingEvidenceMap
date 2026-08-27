# Updater Pipeline — Workflow 01: Lens ingestion

**Status:** LOCKED ARCHITECTURAL DECISION — implementation changes require explicit approval
**Scope:** weekly Lens API ingestion only
**Last reviewed:** 2026-08-27

## Purpose

Retrieve the weekly incremental Lens Scholarly search results without loss of Lens metadata, preserve the raw API responses, and emit canonical JSONL records for the downstream processing pipeline.

This workflow does **not** perform deduplication, screening, annotation, adjudication, topic modelling, master-CSV construction, or dashboard updates.

## Authoritative current inputs

- Search definition: `config/lens_search.json`
- Existing scheduled workflow: `.github/workflows/weekly_update_pipeline.yml`
- Existing harvester: `scripts/lens_weekly_harvest.py`
- Lens API credential: existing repository secret used by the current workflow

The current search configuration defines the salmon/aquaculture scholarly query, excludes `news`, `report`, `dataset`, and `libguide`, and uses the Lens `created` field for weekly incremental retrieval with a 7-day overlap. The existing production harvester uses Lens pagination/scrolling and a 500-record page size.

## Locked design decisions

### 1. Full Lens records

The redesigned Lens API request must **not use the current restrictive `include` list**. The unrestricted Lens response has been experimentally verified and is the source of the richer structured record.

The raw Lens response must be retained losslessly.

### 2. Two JSON layers at ingestion

**Raw Lens JSON** is immutable source evidence. It retains the actual Lens API response envelope and records exactly as returned.

**Canonical JSONL** is the processing input/output representation. Each line is one canonical evidence record. It retains the complete Lens record under a raw-payload field and adds controlled ingestion provenance.

The canonical JSONL is the input contract for Workflow 02 (deduplication).

### 3. JSONL rather than a large JSON array

Canonical records are stored as JSON Lines so that records can be streamed, checkpointed, resumed, and processed independently without loading the entire corpus into memory.

### 4. Identity

`lens_id` is the authoritative evidence-record identifier.

DOI is a secondary bibliographic identifier and must not replace `lens_id` as the record identity. Title is not an identity fallback.

### 5. Run-level versus record-level provenance

Run-level information belongs in a run manifest. Record-level provenance belongs in each canonical record.

### 6. Checkpointing

Successful API batches must be checkpointed frequently. A failed or partial run must not advance the successful-search checkpoint.

The successful-search checkpoint may advance only after the complete ingestion run has succeeded and all required ingestion artefacts have been written successfully.

### 7. Idempotency

Reruns must be safe. `lens_id` is the primary key used to identify an already retrieved record within an ingestion run and when reconciling increments downstream.

### 8. No destructive transformation

CSV is **not** an ingestion format. The workflow must not convert the Lens response to RIS or CSV as an intermediate processing representation.

RIS remains a separate future ingestion adapter: `RIS -> canonical JSONL`.

## Proposed execution boundary

```text
Lens API
  |
  +--> immutable raw response batches
  |       response_000001.json
  |       response_000002.json
  |       ...
  |
  +--> canonical JSONL
          records.jsonl
          |
          v
       Workflow 02: deduplication
```

## Proposed artefacts

Each run should retain, at minimum:

- raw Lens response batches;
- canonical JSONL increment;
- run manifest;
- retrieval/checkpoint state;
- successful-search checkpoint/state only after full success;
- search-history entry.

The exact repository paths are an implementation decision to be made when Workflow 01 is implemented. Existing paths must not be changed merely by this document.

## Run manifest requirements

The manifest should record, at minimum:

- run ID;
- workflow name/version;
- start and completion timestamps;
- search configuration/version or hash;
- search window;
- overlap period;
- Lens-reported total for the search/window;
- number of API batches requested/completed;
- number of raw records received;
- number of records with valid `lens_id`;
- within-run duplicate count;
- number of canonical records emitted;
- pagination method and page size;
- retry/failure information;
- artefact references/checksums where practical;
- final run status.

## Important distinction

The Lens **search-result total** and the **number of records ingested in this run** are different quantities and must remain separate in provenance.

The search-result total is relevant to longitudinal search accounting. The ingested-record count describes actual pipeline input.

## Failure and resume contract

A transient API failure must not cause the workflow to silently lose already retrieved batches or advance the weekly search state.

The workflow should be restartable from the last successful retrieval checkpoint. A partial run must be distinguishable from a completed run.

HTTP 429 handling from the current harvester should be retained. Transient 5xx/network/time-out handling should be made explicit in the implementation design.

## Canonical record boundary

The canonical record should contain, at minimum:

```json
{
  "identity": {
    "lens_id": "..."
  },
  "lens": {
    "raw_payload": { "...complete Lens record..." }
  },
  "provenance": {
    "source": "lens",
    "ingestion_run_id": "...",
    "retrieved_at": "...",
    "batch": 1
  }
}
```

The exact canonical schema remains subject to the field-level data contract being developed before implementation of subsequent workflows.

## Downstream contract

Workflow 02 may assume that Workflow 01 provides:

1. lossless Lens source data;
2. a stable `lens_id` for records where Lens supplied one;
3. one canonical JSONL record per retrieved evidence record;
4. run-level provenance and retrieval counts;
5. a clear success/failure status;
6. resumable artefacts/checkpoints;
7. no screening, annotation, adjudication, topic modelling, or dashboard-specific flattening.

Workflow 02 must not need to reconstruct discarded Lens fields.

## Legacy migration note

The existing 13,389-record corpus is not assumed to have a complete historical JSON/provenance trail. Historical reconstruction will be handled separately. Where historical decisions cannot be established from archived evidence, they must remain unknown/blank rather than being fabricated.

The current correct master state is the priority reference for migration.

## Implementation status

This document locks the **architecture and boundary**, not the implementation. No production Workflow 01 code has been changed as a consequence of this document.

Before implementation, the existing workflow/script must be compared against this contract and a proposed change set explicitly approved.

## Temporary test infrastructure

The temporary `test_lens_full_json.yml` workflow was created to establish the unrestricted Lens response structure. It is experimental infrastructure and must be removed after the schema investigation is complete; it is not part of the production updater architecture.
