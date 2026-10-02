# Workflow 03: publication-status surveillance

## Purpose

Workflow 03 applies publication-status surveillance to the authoritative lean post-Workflow-02 canonical corpus. It produces a sparse publication-status layer keyed by stable canonical `record_id`, flags retracted and withdrawn records for exclusion before relevance screening, and preserves the canonical bibliographic state unchanged for downstream workflows.

This document describes the **current operational architecture on branch `workflow01-final-architecture`**. Historical Workflow 03 launchers and baseline-specific files remain in the repository for provenance and must not be inferred to be current merely from their filenames.

## Current workflow entry point

The current production workflow is:

`.github/workflows/workflow_03_production.yml`

It is the canonical W03 route for current updates. It:

1. restores the registered post-W02 lean checkpoint;
2. verifies its SHA-256 and record count;
3. scans publication status;
4. validates the complete sparse W03 layer;
5. publishes the full validated W03 state to restricted Zenodo;
6. registers the W03 pointer;
7. emits a seven-day W03 handoff cache for W04; and
8. explicitly updates the Shiny current-run progress after publication.

The explicit Shiny update is necessary because registry commits made from a GitHub Actions `GITHUB_TOKEN` do not themselves start another workflow run. The W03 production workflow therefore performs the reporting update directly rather than relying on a second push-triggered workflow.

## Workflows not used as current production

| Workflow | Status |
|---|---|
| `.github/workflows/workflow_03_publish_baseline.yml` | Historical baseline publisher tied to run `36172718538` and the old 32,292-record baseline. |
| `.github/workflows/workflow_03_diagnostic_title_notice_scan.yml` | Historical/diagnostic title-prefix scan tied to old W01/W02 pointers. |
| `.github/workflows/retraction-sweep.yml` | Older separate retraction-cache workflow. It is not the canonical W03 production route. |

## Authoritative input

Workflow 03 consumes the registered lean canonical checkpoint produced after W02.

For the current update:

- source W02 run: `37016080508`;
- W02-to-W03 handoff validation run: `37019284428`;
- canonical records: **47,094**;
- manifestation references: **118,527**;
- lean canonical SHA-256:  
  `2f55621c09af9074051cf9ae969be414541ac5eeab3266a9a86b8f984f7183f2`;
- restricted lean checkpoint Zenodo record: **23104805**;
- DOI: **10.5281/zenodo.23104805**;
- pointer: `docs/compaction/zenodo/run-37016080508.json`.

The workflow first attempts to use the short-lived verified GitHub Actions handoff artefact. If that cache is unavailable or fails checksum validation, it restores the same authoritative lean state from restricted Zenodo.

## Detection evidence

Workflow 03 uses two independent evidence channels:

1. OpenAlex publication-status metadata, including `is_retracted` and OpenAlex work type; and
2. conservative title-prefix detection for explicit publication notices.

Generic prefixes such as “notice”, “warning”, “update”, “comment on”, “response to” and “reply to” are not treated as publication-status evidence by themselves.

## Publication-status vocabulary

Allowed codes are:

- `normal`
- `retracted`
- `withdrawn`
- `corrected`
- `expression_of_concern`
- `warning`

Deterministic precedence is:

`retracted > withdrawn > expression_of_concern > warning > corrected > normal`

Multiple positive signals are retained in provenance. They are not an unresolved conflict when the deterministic precedence rule yields one definitive code.

## Workflow 04 eligibility

`exclude_from_workflow04=true` only for:

- `retracted`; and
- `withdrawn`.

All other publication-status categories remain eligible for W04.

Workflow 04 consumes this flag directly and must not rerun publication-status inference.

## Current full production run: 2 October 2026

The current authoritative W03 production run is:

- GitHub Actions run: **`37024164176`**;
- records scanned: **47,094**;
- normal: **46,978**;
- corrected: **104**;
- retracted: **11**;
- withdrawn: **1**;
- expression of concern: **0**;
- warning: **0**;
- excluded from W04: **12**;
- unresolved evidence conflicts: **0**;
- records with multiple positive signals: **2**.

OpenAlex lookup outcomes:

- found: **37,241**;
- not found: **597**;
- unavailable or error: **9,256**.

The presence of an unavailable/error OpenAlex lookup does not by itself exclude a record. Title-notice evidence is still evaluated and the record remains `normal` unless a positive status signal is present.

## Current durable W03 state

The accepted W03 state is published as a restricted Zenodo record:

- Zenodo record: **23105974**;
- DOI: **10.5281/zenodo.23105974**;
- pointer: `docs/publication_status/zenodo/run-37024164176.json`;
- publication-status SHA-256:  
  `de4a5eb88dca7e30e239eca645ae51bd46de9bb5638ab8b96fa0fe3a34b08cce`;
- upstream lean canonical SHA-256:  
  `2f55621c09af9074051cf9ae969be414541ac5eeab3266a9a86b8f984f7183f2`.

The W03 handoff artefact `workflow03-handoff-37024164176` contains the lean canonical JSONL, publication-status layer and validation report for downstream W04 use.

## Validation rules

A full W03 state is accepted only when:

- the lean canonical input SHA matches the registered pointer;
- the restored record count matches the pointer;
- every scanned record has one stable, non-empty, unique `record_id`;
- the output record count equals the full canonical input count;
- every status code belongs to the allowed vocabulary;
- status counts sum exactly to the scanned population;
- unresolved evidence conflicts equal zero for a published full state; and
- publication and registration complete successfully.

## Storage and provenance

### Repository

GitHub stores:

- W03 production code;
- lightweight W03 Zenodo registry;
- one JSON pointer per accepted W03 state;
- this documentation; and
- current-run progress metadata.

### GitHub Actions

Short-lived operational artefacts include:

- restored lean input;
- publication-status JSONL;
- API audit;
- validation report; and
- seven-day W03 handoff cache for W04.

### Zenodo

The durable authoritative W03 sparse state is archived as a restricted Zenodo record. The complete canonical bibliographic corpus is not duplicated inside W03.

## Historical baseline

The earlier 32,292-record W03 baseline remains provenance only:

- production run: `36172718538`;
- records checked: 32,292;
- records excluded from W04: 9;
- unresolved evidence conflicts: 0.

Historical baseline publishers and diagnostic workflows must not be used as current production entry points.

## Scheduled operation

### Fortnightly update

Current canonical state passes through W03 before W04. The present production workflow performs a full W03 scan of the authoritative lean corpus before publication.

### Periodic full surveillance

A periodic full W03 scan may be used to refresh publication status independently of a new search update. Any newly retracted or withdrawn records must be reflected in the W03 layer before downstream screening/annotation state is rebuilt.

## Downstream handoff

W04 consumes:

1. the exact lean canonical checkpoint used by W03; and
2. the authoritative W03 publication-status layer.

For the current run, W04 must therefore use:

- lean pointer: `docs/compaction/zenodo/run-37016080508.json`; and
- W03 pointer: `docs/publication_status/zenodo/run-37024164176.json`.

These inputs represent **47,094 canonical records**, of which **12 are excluded before W04**, leaving **47,082 W04-eligible records** before relevance-screening reuse and incremental queue construction.

## Reporting status

Workflow 03 is complete for the current update because:

- the W02 lean handoff was checksum-verified;
- all 47,094 canonical records were scanned;
- the publication-status layer contains one unique row per record;
- 12 retracted/withdrawn records are explicitly excluded from W04;
- unresolved evidence conflicts are zero;
- the sparse W03 state is durably archived and registered; and
- the W03 handoff artefact for W04 was created successfully.

**Current Workflow 03 status: complete, archived and ready for Workflow 04.**
