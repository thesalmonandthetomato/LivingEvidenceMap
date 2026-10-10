# Workflow 03: Publication-status surveillance

## Purpose

Evaluate the publication status of records in the lean canonical dataset following metadata enrichment, identifying retractions, withdrawals and other editorial notices before relevance screening.

## Functionality map

```text
[Validated W02 lean canonical pointer]
             |
             v
[Restore data: Actions handoff or Zenodo]
             |
             v
[Verify canonical SHA-256 and record count]
             |
             v
[OpenAlex lookup by DOI; identifier fallback]
             |
             v
[Title notice classification + status decision]
             |
             v
[Status JSONL + API audit + report]
             |
             v
[Schema/record-ID/count validation]
             |
        +----+-----+
        |          |
   [Full run]   [Limited scan]
        |          |
  [Publish to    [No durable
  restricted      handoff]
  Zenodo]
        |
  [Registry and pointer]
        |
        v
[W04 relevance screening]
```

## Components

| Component | Function |
|---|---|
| `.github/workflows/workflow_03_production.yml` | Production workflow definition, held inactive in `.github/workflows-inert/` on this reconstruction branch |
| `scripts/updater/workflow_03_restore_lean_checkpoint.R` | Restores the authoritative incoming lean state from its pointer |
| `scripts/updater/workflow_03_publication_status.R` | Looks up records, classifies publication status and emits audit and report files |
| `scripts/updater/workflow_03_archive_state_to_zenodo.R` | Publishes validated full-run state to restricted Zenodo |
| `scripts/updater/workflow_03_update_zenodo_registry.R` | Maintains the repository registry and pointer |
| `scripts/updater/workflow_03_restore_state_from_zenodo.R` | Restores a published W03 state for downstream consumers |

## Inputs and methodological rules

Input is the W02 lean canonical JSONL checkpoint and its pointer. Before scanning, the workflow checks the SHA-256 and expected record count. The script queries OpenAlex using DOI batches (maximum 100) and may use an OpenAlex identifier where DOI matching is unavailable. Title-prefix notice detection contributes to the classification. Supported publication status codes are `normal`, `retracted`, `withdrawn`, `corrected`, `expression_of_concern` and `warning`; the implementation defines precedence when multiple signals occur. Retracted and withdrawn records are marked for exclusion from W04. OpenAlex lookup failures are recorded and must not be represented as confirmed normal status.

## Processing modes or stages

### Restore and verify input

Restore the lean canonical state from a prior Actions handoff where available, with Zenodo restoration as the durable route. Verify incoming count and hash before scanning.

### Publication-status scan

Produce `publication_status.jsonl`, `api_audit.jsonl` and `report.json` using `--limit` (0 means full input) and `--batch-size` (up to 100).

### Validation and publication

The production workflow validates report status, allowed codes, record identity and output counts. Only a validated full scan is eligible for Zenodo publication and a new registered downstream pointer. Limited runs are diagnostic and do not constitute a published baseline.

## Provenance and documentation

The report stores the input and output SHA-256 checksums, scan counts and publication-status summaries. The API audit records provider lookup failures. The archival receipt links the published layer to its source run and upstream lean-state checksum.

## Storage and archival model

### Permanent repository records

`docs/publication_status/zenodo_registry.csv` and `docs/publication_status/zenodo/run-<run-id>.json` act as lightweight publication locators and provenance records.

### Short-lived GitHub Actions artefacts

The incoming lean-state handoff and workflow execution outputs may be transferred as Actions artefacts. Their precise retention period is not established by this documentation review and should be set as part of the final production configuration.

### Durable external archive

A validated full publication-status layer and manifest are deposited to restricted Zenodo, with receipt and checksum referenced from the repository.

## Downstream handoff

The published W03 state pointer feeds W04. W04 must restore authoritative state, apply exclusion flags for retracted and withdrawn records and preserve status provenance. The source workflow exposes `pointer_path` after publication.

## Methods text for research reporting

> **Publication-status assessment.** Following metadata enrichment, records were assessed for retractions, withdrawals and editorial notices using OpenAlex publication-status metadata and title-based notice indicators. Identified withdrawals and retractions were flagged for exclusion from relevance screening. The resulting record-level status layer was checked for consistency, and the validated full-run layer was archived with checksums and run provenance.

## Reporting status

This document describes the source implementation reviewed on 9 October 2026. No W03 run has been executed or validated on `production-minimal`. A production run should be considered complete only when input integrity checks, status-layer validation, durable publication and the registered handoff succeed.
