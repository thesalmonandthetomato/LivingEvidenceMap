# Workflow 02: Metadata enrichment and repair

## Purpose

Workflow 02 enriches the authoritative canonical records produced by Workflow 01 when a DOI is present but the canonical title and/or abstract remains missing. It preserves Workflow 01 identity and existing populated metadata, accepts only provider metadata that pass deterministic identity and title-consistency checks, quarantines conflicting provider metadata for human review, and stores enrichment as a sparse patch rather than duplicating the full canonical corpus.

Workflow 02 is now designed for incremental living updates. The current production architecture is batched, checkpointed and resumable. Human-review decisions are made in the Shiny adjudication application and, after the final decision is saved, the workflow can resume automatically from the preserved pre-adjudication state.

This document describes the **current operational architecture on branch `workflow01-final-architecture`**. Historical Workflow 02 files remain in the repository for provenance and will be dealt with during the later repository-cleanup stage; they must not be inferred to be current merely from their filenames.

## Current workflow entry points

### Workflows currently used

| Role | Workflow | Current status |
|---|---|---|
| Operator-facing production entry point | `.github/workflows/workflow_02_batched_production.yml` | **Current production route for subsequent W02 updates.** It calls the reusable batched engine in incremental mode, batch size 250, publication enabled and Scopus currently disabled. Its GitHub Actions display name still contains “candidate”; that label is a naming artefact pending repository cleanup. |
| Reusable production engine | `.github/workflows/workflow_02_batched.yml` | **Current W02 engine.** Restores W01 and prior W02 state, plans deterministic batches, writes durable batch checkpoints, aggregates them, builds human-review state, validates replay and publishes accepted sparse W02 state. |
| Automatic post-human-review resume | `.github/workflows/workflow_02_resume_after_human_review.yml` | **Current automatic resume route.** A Shiny completion request under `docs/shiny_adjudication/w02_resume_requests/` triggers this workflow directly. It validates the matching queue and decisions, reconstructs the preserved source-run patch, applies human decisions, replay-validates, publishes/registers W02 and acknowledges the consumed Shiny batch. Controlled validation passed in run `37022918123`. |
| Production architecture validation | `.github/workflows/workflow_02_validate_production_architecture.yml` | Current structural validation workflow for W02 production behaviour. |
| W02-to-W03 handoff for the 2 October 2026 update | `.github/workflows/tmp_publish_w02_to_w03_handoff_37016080508.yml` | **One-off only, not canonical.** Used because this update originated from the older serial W02 run. It successfully created and restored the lean W03 checkpoint. |

### Workflows that are not the current production route

The following files remain for provenance or historical baselines and should **not** be used for a new W02 update:

| Workflow | Status |
|---|---|
| `.github/workflows/workflow_02_production.yml` | Legacy serial production route. The 2 October 2026 update originated here before the batched architecture was designated for future production. |
| `.github/workflows/workflow_02_post_w02_lean_compaction.yml` | Historical baseline-specific compaction workflow. It still contains old fixed pointers/counts from the 32,292-record baseline and is not suitable for a current update. |
| `.github/workflows/workflow_02_publish_post_w02_lean_checkpoint.yml` | Historical baseline-specific publisher, likewise tied to old run IDs/counts. Do not use for a current update. |
| `.github/workflows/workflow_02_resume_request_listener.yml` | Superseded listener. It is manual-only; automatic resume is handled directly by `workflow_02_resume_after_human_review.yml`. |
| `tmp_*workflow02*` and other temporary W02 launchers | Validation/recovery provenance only. They are not production entry points. |

A generic, count-agnostic W02-to-W03 handoff workflow still needs to be canonicalised during the planned workflow audit. For the current update, the handoff itself has already been validated successfully, but the one-off handoff launcher is not to be reused as the general production entry point.

## Current architecture

```text
authoritative Workflow 01 canonical state
              |
              v
workflow_02_batched_production.yml
              |
              v
workflow_02_batched.yml
              |
              |-- restore and checksum W01
              |-- restore previous W02 sparse state
              |-- apply previous sparse patch
              |-- select DOI + missing title/abstract records
              |-- deterministic batch plan
              |-- durable batch checkpoints
              |
              v
          Europe PMC
              |
              |-- exact DOI required
              |-- title-consistency guard where applicable
              |
              v
   optional Scopus fallback
   (currently disabled in production)
              |
              v
      build sparse current patch
              |
              |-- exact batch replay
              |-- merge cumulative patch
              |-- cumulative reconstruction check
              |
              +------------------------------+
              |                              |
       no conflicts                    quarantined conflicts
              |                              |
              |                              v
              |                    checksum-locked Shiny queue
              |                              |
              |                         human decisions
              |                              |
              |                              v
              |          workflow_02_resume_after_human_review.yml
              |                              |
              +---------------+--------------+
                              |
                              v
                   final replay validation
                              |
                              v
                 restricted Zenodo W02 state
                              |
                              v
                    registered W02 pointer
                              |
                              v
                 validated lean W03 handoff
```

## Authoritative inputs

Workflow 02 consumes:

1. the exact published Workflow 01 pointer supplied for the update; and
2. the latest accepted published Workflow 02 pointer, where one exists.

The W01 canonical checksum is verified before processing. A previous W02 cumulative patch is restored from restricted Zenodo and applied in fill-missing mode so that newer authoritative W01 metadata take precedence over older enrichment.

For the current update, the accepted W01 state contains **47,094 canonical records** and **118,527 source manifestations**.

## Eligibility

The current batched planner selects a record for W02 provider lookup only when:

- a DOI is present; and
- the canonical title or canonical abstract is missing.

Author keywords may be retained or opportunistically enriched when a provider response already required for title/abstract repair contains them, but **missing keywords alone do not make a record eligible for W02 lookup**.

This is the current production eligibility contract implemented by `scripts/updater/workflow_02_plan_batches.R`.

## Existing-field protection

Workflow 02 does not overwrite populated authoritative title or abstract fields during automated enrichment.

Sparse-patch construction and replay checks protect:

- stable `record_id`;
- DOI;
- source manifestations;
- existing populated canonical fields; and
- unrelated canonical metadata.

Conflicting candidate metadata are quarantined rather than silently applied.

## Provider behaviour

### Europe PMC

Europe PMC is the first provider.

Provider metadata are accepted only when the returned DOI exactly matches the requested normalised DOI. Where both canonical and provider titles exist, guarded fields require title consistency using the established Jaro-Winkler threshold of at least 0.90.

### Scopus

Scopus remains implemented as an optional fallback after Europe PMC for residual missing title/abstract metadata.

The underlying enrichment script retains:

- direct Abstract Retrieval by DOI;
- DOI search followed by EID retrieval where required;
- exact returned-DOI validation;
- title-consistency guarding;
- rate-limit response handling;
- `Retry-After` / `X-RateLimit-Reset` interpretation;
- a circuit breaker for repeated rate-limit failures; and
- technical retry provenance.

However, **Scopus is currently disabled in the operator-facing production wrapper**:

```text
workflow_02_batched_production.yml
use_scopus: false
```

When Scopus is disabled, unresolved metadata after Europe PMC are retained unchanged and are not classified as Scopus technical failures.

This avoids consuming or repeatedly probing an exhausted Scopus weekly quota while preserving the option to re-enable Scopus later.

## Batching and checkpoints

The current production wrapper uses batches of up to **250 records**. The reusable engine supports different batch sizes, but production should use the wrapper unless a deliberately controlled validation or repair run requires otherwise.

The batched engine:

- plans the due set deterministically;
- writes immutable batch inputs;
- retains durable batch checkpoints;
- supports checkpoint reuse after interruption;
- aggregates current patches across batches;
- validates exact batch replay; and
- retains a prepared finalisation state that can be used after human adjudication.

The current matrix remains conservative at `max-parallel: 1`; concurrency should not be increased without a separate provider-rate-limit validation.

## Human-review gate and automatic resume

Provider conflicts are converted to a checksum-locked W02 review queue and published to the Shiny adjudication application.

For a normal batched production run:

1. W02 preserves the immutable prepared state and batch checkpoints.
2. The Shiny app displays the W02 conflict cases.
3. Decisions are written to the W02 decisions store.
4. When all active cases have a non-`uncertain` decision, the Shiny app creates a completion request under:
   `docs/shiny_adjudication/w02_resume_requests/`.
5. That push directly triggers:
   `.github/workflows/workflow_02_resume_after_human_review.yml`.
6. The workflow verifies that the active queue belongs to the requested source run and that its reconstructed SHA matches the locked queue SHA.
7. The latest active decision for every review case is required.
8. Human decisions are applied to the preserved current W02 patch.
9. The current and cumulative states are replayed and checksum-verified.
10. The resumed W02 state is published and registered.
11. The Shiny batch is marked consumed.
12. A validated W02 handoff artefact is emitted.

A non-destructive controlled validation of this trigger/request path passed in GitHub Actions run **`37022918123`**. In that validation, the request was parsed successfully, the validation-only job passed and the real resume job was skipped, so no W02 state was modified.

## Sparse state and retry behaviour

W02 is a sparse enrichment layer over W01. The durable state consists primarily of:

- cumulative enrichment patch;
- enrichment audit;
- provider/retry state;
- final inventory;
- replay/provenance reports; and
- state manifest.

Technical provider failures are separately identifiable and can be revisited in a controlled repair mode.

Successful/no-result attempts can be deferred by the configured recheck interval, currently 90 days by default.

When Scopus is disabled, a skipped Scopus fallback is not treated as a technical failure.

## Publication

Accepted W02 state is archived as a restricted Zenodo record and registered in:

- `docs/enrichment/zenodo_registry.csv`; and
- `docs/enrichment/zenodo/run-<run_id>.json`.

The fully enriched canonical JSONL does not need to be committed to Git. It is reproducible from the exact W01 state plus the registered cumulative W02 sparse patch.

## Current accepted W02 state: 2 October 2026

The current update originated from an older serial W02 production run and therefore required a one-off finalisation path after the batched architecture had already been selected for future production. This exception does **not** define the future W02 production route.

Accepted W02 state:

- finalisation run: **`37016080508`**;
- canonical records: **47,094**;
- source manifestations: **118,527**;
- cumulative sparse patch records: **3,434**;
- current Shiny KPI count with enrichment data: **2,218**;
- final enriched canonical SHA-256:  
  `5b38fcd72b19119d7c8b435b7cd9a2a24f262537300985cdcc7086b93380b091`;
- restricted Zenodo record: **23104611**;
- DOI: **10.5281/zenodo.23104611**;
- repository pointer: `docs/enrichment/zenodo/run-37016080508.json`.

The source run had encountered Scopus weekly quota exhaustion. Those Scopus technical outcomes were retained as provenance/retry state; no new Scopus requests were required to finalise the accepted W02 state.

## Current validated W02-to-W03 handoff

For this update, the W02-to-W03 handoff was validated by one-off run **`37019284428`**.

That run:

- verified the final W02 canonical SHA;
- compacted the 47,094-record canonical state to the lean downstream representation;
- preserved all stable record identities and manifestation references;
- published a restricted lean checkpoint;
- registered the checkpoint; and
- restored the published checkpoint through the W03 restore script and verified the restored SHA and record count.

Accepted lean handoff state:

- source W02 run: **`37016080508`**;
- publication/validation run: **`37019284428`**;
- canonical records: **47,094**;
- manifestations/references: **118,527**;
- lean canonical SHA-256:  
  `2f55621c09af9074051cf9ae969be414541ac5eeab3266a9a86b8f984f7183f2`;
- restricted Zenodo record: **23104805**;
- DOI: **10.5281/zenodo.23104805**;
- pointer: `docs/compaction/zenodo/run-37016080508.json`.

The older `workflow_02_post_w02_lean_compaction.yml` and `workflow_02_publish_post_w02_lean_checkpoint.yml` remain tied to the historical 32,292-record baseline and must not be used for a new update. A generic count-agnostic handoff entry point should be selected or built during the forthcoming W03/W02 audit before it is treated as canonical for future cycles.

## Historical baseline

The earlier validated full baseline remains useful provenance but is no longer the current operational state.

Historical baseline:

- production run: `36137804187`;
- W01 canonical records: 32,292;
- W02 cumulative patch records: 3,434;
- enriched canonical SHA-256:  
  `c88d36631512b5b30853fb3ae271db2e456b2a8b5b94925ccf0840e8f8d9156b`;
- restricted Zenodo record: 22960664;
- DOI: 10.5281/zenodo.22960664.

Finite correction work performed while establishing that historical baseline is documented separately in `AD_HOC_ACTIONS.md`. It must not be interpreted as part of the current automated production path.

## Provenance recorded by W02

Where applicable, Workflow 02 records:

- upstream W01 pointer and canonical SHA-256;
- previous W02 lineage;
- stable `record_id`;
- normalised DOI;
- missing-field state before and after enrichment;
- Europe PMC outcome;
- Scopus outcome where Scopus is enabled;
- provider attempts and rate-limit state;
- accepted field provenance;
- title similarity for guarded fills;
- quarantined conflict reason;
- technical-error/retry state;
- configured recheck period;
- batch input/checkpoint checksums;
- current and cumulative patch checksums;
- final enriched canonical SHA-256;
- final inventory;
- human-review queue SHA;
- human-decision application manifest;
- GitHub Actions run IDs;
- Zenodo record identifier/DOI;
- archive and manifest checksums.

## Storage model

### GitHub

Permanent lightweight records include:

- current W02 workflow definitions and scripts;
- methodology/documentation;
- Zenodo registry;
- small Zenodo pointers;
- current-run reporting metadata.

### GitHub Actions artefacts

Short-lived operational artefacts include:

- immutable batch inputs;
- batch checkpoints;
- prepared finalisation state;
- human-review package;
- resumed human-review state;
- materialised W02 handoff JSONL.

These are operational caches, not the durable source of truth.

### Zenodo

Restricted Zenodo records provide the durable sparse W02 state and the accepted lean downstream checkpoint.

## Methods text for research reporting

> **Workflow 02: bibliographic metadata enrichment.** Canonical records with a DOI but a missing title or abstract were subjected to deterministic metadata enrichment. Europe PMC was queried first, with metadata accepted only where the returned DOI exactly matched the requested normalised DOI and title-consistency requirements were met where applicable. Scopus was available as a configurable fallback for residual title/abstract gaps but could be disabled operationally, for example when provider quota was unavailable; disabling the provider left unresolved metadata unchanged rather than treating the absence of a Scopus call as a technical failure. Existing populated canonical metadata were not overwritten automatically. Conflicting provider metadata were quarantined for human adjudication in a checksum-locked review queue. Enrichment was stored as a sparse patch keyed to stable canonical work identifiers, and batch, current and cumulative patch states were replayed against their authoritative inputs before archival. After human review, completed decisions were validated against the locked queue and applied before final replay, publication and downstream handoff.

## Completion criteria

Workflow 02 is complete for an update when:

- authoritative W01 state is checksum-verified;
- prior W02 sparse state is restored where applicable;
- the deterministic due set is processed or explicitly deferred;
- existing populated authoritative metadata are preserved;
- every automated accepted fill satisfies provider identity/consistency rules;
- any conflicts are quarantined;
- any required Shiny adjudication is complete;
- human decisions are bound to the correct queue SHA;
- current and cumulative sparse states replay exactly;
- final W02 state is deposited to restricted Zenodo and registered;
- the final W02 canonical checksum is recorded; and
- the downstream W03 handoff can be restored and checksum-verified.

For the 2 October 2026 update, these conditions were satisfied by W02 finalisation run `37016080508` plus W02-to-W03 handoff validation run `37019284428`.

**Current W02 status: complete for this update; W03 handoff validated. Future W02 production should use the batched production route documented at the top of this file.**
