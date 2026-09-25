# Workflow 01: Multi-source deduplication, adjudication and canonicalisation

## Purpose

Workflow 01 converts the bibliographic manifestations retrieved by Workflow 00 into a source-agnostic canonical corpus of scholarly works. It preserves every source manifestation from Lens, Scopus, OpenAlex, AGRICOLA and Web of Science, carries forward previously resolved duplicate decisions, evaluates only the new or changed deduplication state, applies deterministic and model-assisted duplicate adjudication, supports cryptographically locked human review, applies approved metadata repairs, preserves stable work identifiers, and materialises the canonical JSONL consumed by Workflow 02.

The workflow is designed as a persistent state machine rather than a succession of independent full rebuilds. A validated full baseline is retained once; subsequent accepted changes are stored as immutable deltas that can be replayed exactly to reconstruct the current Workflow 01 state.

This document serves two purposes:

1. as a methodological guide to the repository implementation; and
2. as source text for reporting Workflow 01 in a research paper.

## Functionality map

```text
Workflow 00 restricted Zenodo run
          |
          v
restore + checksum-verify selected source outputs
          |
          v
restore previous Workflow 01 state
(full baseline + zero or more immutable deltas)
          |
          v
preserve untouched sources + append newly observed manifestations
          |
          v
provenance-safe five-source union
          |
          v
incremental duplicate-candidate generation
          |
          v
deterministic duplicate classification
          |
          v
residual ambiguous pairs
          |
          v
LLM adjudication
          |
     +----+-------------------------------+
     |                                    |
no human review required            human review required
     |                                    |
     |                              locked review queue
     |                                    |
     |                           compact pre-adjudication
     |                            checkpoint to Zenodo
     |                                    |
     |                          human decisions + repairs
     |                                    |
     |                              integrity validation
     |                                    |
     +--------------------+---------------+
                          |
                          v
                final pair-decision state
                          |
                          v
              stable work-cluster assignment
                          |
                          v
        cumulative strip/repair provenance applied
                          |
                          v
               canonical records.jsonl
                          |
                          v
                 build immutable delta
                          |
                          v
           replay previous state + delta
           and require exact target state
                          |
                          v
              restricted Zenodo delta archive
                          |
                          v
                       Workflow 02
                metadata enrichment/repair
```

## Components

| Component | Function |
|---|---|
| `.github/workflows/workflow_01_production.yml` | Production controller for restoring the previous Workflow 01 state, ingesting a Workflow 00 source subset, incremental deduplication, adjudication, canonicalisation, delta construction, replay validation and archival. |
| `.github/workflows/workflow_01_resume_after_human_review.yml` | Resumes a paused Workflow 01 run from a compact pre-adjudication checkpoint after locked human decisions and repairs have been supplied. |
| `scripts/updater/workflow_01_restore_current_state.R` | Reconstructs the latest authoritative Workflow 01 state by restoring the full baseline and replaying the registered delta chain. |
| `scripts/updater/workflow_01_restore_workflow00_from_zenodo.R` | Restores selected Workflow 00 source outputs from restricted Zenodo storage and verifies the archived inputs. |
| `scripts/updater/workflow_01_deduplication_build_union.R` | Builds the prior-plus-new five-source manifestation union while preserving prior source state and manifestation identity. |
| `scripts/updater/workflow_01_deduplication_incremental_candidates.R` | Constructs the normalised comparison representation and generates candidate pairs involving new or changed manifestations. |
| `scripts/updater/workflow_01_deduplication_incremental_score.R` | Scores the incremental candidate set. |
| `scripts/updater/workflow_01_deduplication_identifier_rescore.R` | Applies the deterministic duplicate-classification rules to incremental candidates. |
| `scripts/updater/workflow_01_llm_adjudicate_duplicates.R` | Adjudicates residual ambiguous duplicate candidates using the configured language model and confidence threshold. |
| `scripts/updater/workflow_01_render_human_review_batch.R` | Renders human-review cases mechanically from the locked queue. |
| `scripts/updater/workflow_01_validate_human_review_state.R` | Enforces exact queue membership, queue checksum and decision/repair integrity before human decisions can affect clustering. |
| `scripts/updater/workflow_01_build_pending_checkpoint.R` | Builds the compact state required to pause safely for human review without archiving the entire corpus again. |
| `scripts/updater/workflow_01_archive_pending_checkpoint_to_zenodo.R` | Archives the compact human-review checkpoint as a restricted Zenodo record. |
| `scripts/updater/workflow_01_restore_pending_checkpoint.R` | Restores and verifies a compact human-review checkpoint. |
| `scripts/updater/workflow_01_apply_adjudications_and_recluster.R` | Applies final adjudications and reconstructs work clusters while preserving stable work IDs and recording cluster aliases when works merge. |
| `scripts/updater/workflow_01_merge_cumulative_repairs.R` | Carries forward approved metadata-repair and abstract-strip provenance across successive runs. |
| `scripts/updater/workflow_01_build_canonical_jsonl.R` | Materialises one source-agnostic canonical JSON object per final work while retaining all constituent source manifestations. |
| `scripts/updater/workflow_01_build_delta.R` | Compares the reconstructed previous state with the new target and emits only source additions, state upserts, canonical upserts, retired IDs and provenance changes. |
| `scripts/updater/workflow_01_replay_delta.R` | Replays an immutable delta onto the previous state and verifies the resulting source state, pair state, cluster state and canonical JSONL against the target. |
| `scripts/updater/workflow_01_archive_delta_to_zenodo.R` | Deposits the immutable Workflow 01 delta and manifest to restricted Zenodo storage. |
| `scripts/updater/workflow_01_write_run_report.R` | Produces machine-readable and human-readable run reports. |
| `docs/deduplication/zenodo_registry.csv` | Repository registry linking durable Workflow 01 states to Zenodo records and lineage. |
| `docs/deduplication/zenodo/run-*.json` | Lightweight repository pointers to full-baseline or delta records. |

## Inputs and methodological rules

### Authoritative input state

Workflow 01 has two authoritative inputs for an update:

1. the selected Workflow 00 restricted Zenodo pointer, identifying the exact source harvests to be incorporated; and
2. the latest Workflow 01 pointer, identifying the previously accepted baseline-plus-delta state.

The production workflow validates both pointers before processing. Workflow 00 source subsets may contain Lens, Scopus, OpenAlex, AGRICOLA and/or Web of Science. Sources not present in the new Workflow 00 run are preserved from the previous Workflow 01 state rather than silently dropped.

### Manifestation identity and source preservation

Each bibliographic manifestation is identified by its source namespace plus native source record identifier. The union step preserves previous manifestations and appends genuinely new manifestations. The intended model is additive: an update must not silently rewrite historical source identity.

All source manifestations remain represented within the canonical work record. Deduplication therefore collapses publications at the work level without destructively deleting the source records from which the work was inferred.

### Duplicate-candidate generation

Workflow 01 does not repeat an all-pairs comparison of the complete historical corpus on every update. Previously resolved pair state is restored, and new candidate generation is restricted to comparisons required by newly introduced manifestations.

Bibliographic comparison uses identifiers and bibliographic evidence including titles, authorship, publication year, journal, pagination and abstract information. Shared DOI is evidence but is not treated as sufficient evidence of duplication in isolation.

### Deterministic classification and model adjudication

Deterministic rules resolve cases where the bibliographic evidence is sufficiently strong. Residual ambiguous pairs are passed to the configured language model using the Workflow 01 duplicate-adjudication prompt.

The production controller exposes the model and automatic-promotion confidence threshold as explicit inputs. The default threshold is 0.95. Model-assisted adjudication distinguishes different manifestations of the same publication from distinct outputs arising from the same study.

Substantive uncertainty and technical failure are not silently coerced into duplicate or non-duplicate states.

### Human-review integrity gate

Cases requiring human adjudication are rendered from an immutable review queue. The queue is bound to its manifest by SHA-256. Submitted decisions are validated against the exact expected case set before they are allowed to affect clustering.

If human review is required, the production run stops downstream promotion and stores a compact pre-adjudication checkpoint. The checkpoint contains only the new source manifestations and the incremental state needed to resume, together with the locked review queue and lineage pointers. The resume workflow restores the previous authoritative state plus this checkpoint, validates the submitted decisions and repairs, and continues from the adjudication boundary without rerunning the completed search or model stages.

### Metadata-repair actions

Human adjudication can generate immutable, manifestation-specific metadata repairs. Supported repair actions include:

- `strip_abstract`;
- `replace_abstract`;
- `set_doi`;
- `set_title`; and
- `set_canonical_preference`.

Repairs target a named source manifestation and are applied during canonical materialisation. A canonical-preference decision defines a preferred subset of manifestations for field selection; it is not treated as requiring exactly one preferred manifestation per final work.

Repair application is separately audited. Approved repairs must map uniquely and be recorded as applied; unapplied approved repairs cause validation failure.

### Stable work identifiers

Existing work identifiers are preserved across updates whenever the corresponding historical work remains identifiable in the updated cluster structure.

For a newly observed work, a deterministic work ID is created. If multiple previously distinct works later merge, one existing work ID survives deterministically and the retired IDs are recorded as aliases. A historical work splitting into multiple current clusters is treated as an integrity failure rather than silently issuing replacement identities.

This keeps downstream work identity stable across routine updates.

### Canonical field selection

Canonical bibliographic fields are selected independently of source priority. Where multiple usable manifestation values are available, Workflow 01 selects deterministically from the available evidence. Human canonical-preference decisions constrain selection to the preferred subset for a field when that subset contains usable values; otherwise selection falls back to the full cluster.

The final JSONL is intentionally sparse. Internal repair-selection mechanics are retained in provenance/audit artefacts rather than adding default repair fields to every canonical record.

## Processing stages

### 1. Restore previous authoritative state

The latest Workflow 01 pointer may reference either the original full baseline or a later delta. `workflow_01_restore_current_state.R` follows the lineage back to the full baseline, restores the baseline, verifies it, and replays each registered delta in sequence.

The resulting local state contains the current source manifestations, pair-decision state, manifestation-to-cluster map, canonical JSONL and cumulative repair/strip provenance.

### 2. Restore current Workflow 00 source subset

The new Workflow 00 archive is restored from restricted Zenodo storage. Only sources declared in the Workflow 00 pointer are treated as updated. Other source inputs are copied from the previous Workflow 01 state.

### 3. Build the provenance-safe source union

The restored historical source state and new Workflow 00 source material are combined into the current five-source manifestation state.

### 4. Generate and score incremental duplicate candidates

Candidate generation identifies comparisons required for newly introduced manifestations. Candidate rows are scored and passed through the deterministic duplicate classifier. Previously final pair decisions are preserved.

### 5. Adjudicate residual candidate pairs

Residual ambiguous cases are submitted to the configured LLM. Cases eligible for automatic promotion are incorporated at the configured confidence threshold. Remaining cases are routed to human review.

### 6. Pause and resume for human review when necessary

When the human-review queue is non-empty, Workflow 01 writes a compact checkpoint and restricted Zenodo pointer and stops before final publication.

The resume workflow validates the completed human decisions and repair ledger against the locked queue checksum, reconstructs the exact pre-adjudication state, and continues without repeating completed upstream work.

### 7. Reconstruct stable work clusters

Final duplicate edges are applied and work clusters are reconstructed. Existing IDs are retained where possible, new IDs are assigned deterministically, mergers generate aliases, and prohibited historical splits fail validation.

### 8. Apply cumulative metadata repairs and materialise canonical JSONL

Approved repair and abstract-strip state is merged cumulatively with the previous state. The canonical builder then writes one JSON object per work and retains the constituent source manifestations inside each work record.

### 9. Build an immutable delta

After canonical materialisation, Workflow 01 compares the target state against the previous reconstructed state and writes only differences:

- new source manifestations;
- pair-decision upserts;
- cluster-map upserts;
- cluster-ID aliases;
- canonical-record upserts;
- retired canonical IDs;
- data-quality repair upserts;
- abstract-strip-action upserts; and
- target manifests and lineage metadata.

### 10. Replay the delta before publication

A delta is not accepted merely because it can be constructed. Workflow 01 immediately replays it onto the previous state and requires the replayed result to match the target.

The replay gate verifies:

- exact reconstructed source state;
- semantic pair-decision state;
- semantic manifestation-cluster state; and
- exact SHA-256 equality of the reconstructed canonical JSONL.

Only a replay-valid delta is eligible for durable archival.

## Provenance and documentation

Workflow 01 records, where applicable:

- Workflow 00 parent run and Zenodo lineage;
- previous Workflow 01 run and Zenodo lineage;
- source namespace and source-native identifiers;
- source-manifestation counts by source;
- candidate-generation state;
- deterministic rule classifications;
- LLM model, confidence and decision state;
- human review-case IDs;
- locked queue SHA-256;
- approved human decisions and repair actions;
- repair-application audit;
- cumulative abstract-strip actions;
- stable cluster IDs and retired-ID aliases;
- canonical record count;
- canonical JSONL byte size and SHA-256;
- pair-decision semantic state hash;
- cluster-map semantic state hash;
- delta cardinalities;
- GitHub Actions run identifiers;
- Zenodo record identifiers and DOI;
- archive filenames, sizes and SHA-256 checksums; and
- manifest checksums.

Completed runs can additionally generate JSON and Markdown reports under `docs/deduplication/runs/`.

## Storage and archival model

### Permanent repository records

GitHub stores lightweight implementation, methodology and lineage material, including:

- Workflow 01 R scripts and Actions workflows;
- this functionality/methods report;
- human-decision and repair ledgers where appropriate;
- run reports;
- `docs/deduplication/zenodo_registry.csv`; and
- one small JSON pointer per durable Workflow 01 baseline, delta or pre-adjudication checkpoint.

The canonical corpus itself is not stored in Git.

### Short-lived GitHub Actions artefacts

Actions artefacts are operational validation and recovery aids rather than the authoritative long-term corpus store. Validation runs may retain manifests, repair audits, deltas and replay audits temporarily.

### Durable external archive

The first accepted complete Workflow 01 state is stored as a restricted full Zenodo baseline.

Subsequent accepted changes are stored as restricted immutable delta records rather than republishing the complete corpus on every update. Each delta records its previous-state lineage and target state checksums.

Runs that require human review store a restricted compact pre-adjudication checkpoint instead of a full corpus copy.

The current state is therefore reproducible from:

```text
full baseline
    +
ordered immutable delta chain
    =
current Workflow 01 state
```

Repository pointers and the Zenodo registry provide the durable lineage needed to reconstruct that chain.

## Validated baseline and repair state

The accepted full baseline is Workflow 01 run `36103542054`, archived as restricted Zenodo record `22953437` with DOI `10.5281/zenodo.22953437`.

That baseline contains:

- 90,137 source manifestations;
- 32,292 canonical works;
- 22,956 duplicate clusters;
- 9,336 singleton clusters; and
- zero unresolved pair decisions.

The baseline source manifestation counts are:

| Source | Manifestations |
|---|---:|
| Lens | 24,135 |
| Scopus | 19,948 |
| OpenAlex | 28,134 |
| AGRICOLA | 2,744 |
| Web of Science | 15,176 |

The baseline canonical JSONL SHA-256 is:

`40eaf26efc73a59a427b05c0ef7d30af33e993edf9c9993ba1d7984c06e4bd9b`

The complete approved metadata-repair set contains 32 repair actions. Full-corpus validation run `36128255337` demonstrated that:

- all 32 approved repairs were applied;
- the repaired corpus remained 90,137 manifestations and 32,292 canonical works;
- the repair-only delta contained zero new source manifestations;
- the repair-only delta contained zero pair-decision upserts;
- the repair-only delta contained zero cluster-map upserts;
- only 17 canonical records required upsert;
- no canonical IDs were retired;
- baseline plus the repair delta reproduced the target pair and cluster state; and
- baseline plus the repair delta reproduced the repaired canonical JSONL exactly by SHA-256.

Stable-ID validation run `36109881761` separately passed preservation, deterministic merge-alias and historical-split rejection tests.

The fast delta/replay development fixture passed in run `36127982002`. The expensive full repair/replay validator is gated separately and is not intended to run on every implementation edit.

## Downstream handoff

The authoritative downstream object is the reconstructed and checksum-verified canonical `records.jsonl`.

Workflow 02 is responsible for metadata enrichment/repair. It must consume this canonical JSONL directly, preserve work identity and existing canonical/source provenance, and only alter bibliographic fields under its own verified enrichment rules.

The Workflow 01 → Workflow 02 interface is considered valid only when Workflow 02 can consume the canonical JSONL without a schema adapter and its output can be traced back to the exact Workflow 01 canonical checksum.

## Methods text for research reporting

> **Workflow 01: multi-source deduplication and canonicalisation.** Search results from Lens, Scopus, OpenAlex, AGRICOLA and Web of Science were reconciled using an R-based persistent deduplication workflow. Source-native record identities and previously resolved duplicate decisions were preserved across updates, so newly retrieved manifestations were compared incrementally rather than rebuilding historical deduplication state. Bibliographic candidate pairs were assessed using identifiers and publication metadata, with deterministic rules resolving well-supported cases and residual ambiguity subjected to language-model adjudication and, where required, checksum-locked human review. Human adjudication could also specify auditable manifestation-level metadata repairs. Final duplicate decisions were converted into stable work clusters that retained all constituent database manifestations and preserved existing work identifiers across updates. The source-agnostic canonical JSONL was then materialised deterministically. After the initial complete state was archived, subsequent accepted changes were stored as immutable deltas. Every delta was replayed against the previous authoritative state before publication and was required to reproduce the target pair state, cluster state and canonical JSONL checksum exactly. Full states, deltas and human-review checkpoints were retained as restricted Zenodo records with repository-held lineage pointers and checksums.

## Reporting status

Workflow 01 can be considered validated at the baseline/canonicalisation level when:

- the full five-source baseline is checksum-verified;
- no unresolved pair decisions remain;
- stable work-ID behaviour has passed preservation, merge and split-integrity tests;
- all approved metadata repairs are uniquely mapped and applied;
- canonical materialisation passes record and manifestation cardinality checks;
- an accepted delta is sparse with respect to the actual changed state;
- replay of the delta reproduces the target pair and cluster state;
- replay reproduces the target canonical JSONL exactly by SHA-256;
- durable Zenodo lineage and repository pointers are available; and
- the canonical JSONL is available for the Workflow 02 handoff.

As of full validation run `36128255337`, those baseline/canonicalisation conditions are satisfied for the 90,137-manifestation state and its approved metadata repairs.

End-to-end validation of future Workflow 00 update modes is intentionally deferred and should be performed independently across the complete pipeline once downstream workflows have been finalised.
