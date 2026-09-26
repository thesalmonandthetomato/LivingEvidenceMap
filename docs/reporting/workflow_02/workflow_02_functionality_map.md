# Workflow 02: Metadata enrichment and repair

## Purpose

Workflow 02 enriches the canonical work records produced by Workflow 01 when bibliographic metadata remain incomplete. It operates only on canonical records with a DOI and a missing title and/or abstract, queries Europe PMC first and Scopus second, applies only verified missing-field fills, quarantines conflicting provider metadata, and preserves Workflow 01 work identity, source manifestations and existing populated metadata.

Workflow 02 is implemented as a sparse enrichment layer over the immutable Workflow 01 canonical corpus. It does not republish the complete canonical JSONL on every run. Instead, the automated production process stores a cumulative enrichment patch keyed by stable Workflow 01 `record_id`, plus provider audit, retry state and corpus-quality reports. The enriched canonical JSONL is reconstructed deterministically by applying that patch to the exact upstream Workflow 01 canonical checksum.


This document serves two purposes:

1. as a methodological guide to the repository implementation; and
2. as source text for reporting Workflow 02 in a research paper.

## Functionality map

```text
authoritative Workflow 01 canonical JSONL
          |
          v
restore + verify Workflow 01 state
          |
          v
apply previous Workflow 02 cumulative patch, if any
          |
          v
scan canonical records
          |
          |-- DOI absent --------------------------> unchanged
          |
          |-- title + abstract already present ---> unchanged
          |
          '-- DOI present + title/abstract missing
                         |
                         v
                   Europe PMC lookup
                         |
              exact normalised DOI required
                         |
              +----------+-----------+
              |                      |
        metadata filled         metadata still missing
              |                      |
              |                      v
              |                 Scopus lookup
              |                      |
              |          direct DOI retrieval, then
              |          DOI search + EID fallback
              |                      |
              +----------+-----------+
                         |
                title-consistency guard
                         |
              +----------+-----------+
              |                      |
         verified fill        conflict/quarantine
              |
              v
        enriched canonical state
              |
              v
        build sparse current patch
              |
              v
        exact current-patch replay
              |
              v
        merge cumulative patch state
              |
              v
 apply cumulative patch to pristine Workflow 01
 and require exact enriched-state reconstruction
              |
              v
       post-enrichment inventory
              |
              v
  restricted Zenodo automated enrichment state
              |
              v
 authoritative post-Workflow-02 canonical state
              |
              v
           Workflow 03
```

## Components

| Component | Function |
|---|---|
| `.github/workflows/workflow_02_production.yml` | Reusable production controller for restoration, enrichment, patch construction, replay validation, inventory and optional publication. |
| `.github/workflows/workflow_02_validate_handoff.yml` | Validates the Workflow 01 canonical JSONL interface against the actual enrichment implementation. |
| `.github/workflows/workflow_02_validate_patch_fast.yml` | Validates sparse patch construction and exact replay using a real-record fixture without new provider calls. |
| `.github/workflows/workflow_02_validate_production_architecture.yml` | Validates first-run and immediate second-run state behaviour, including no-op retry deferral. |
| `scripts/updater/workflow_02_metadata_enrichment.R` | Performs DOI-based metadata enrichment using Europe PMC followed by Scopus. |
| `scripts/updater/workflow_02_validate_canonical_handoff.R` | Scans the complete Workflow 01 canonical corpus for schema, identity and eligibility compatibility. |
| `scripts/updater/workflow_02_build_patch.R` | Converts newly applied enrichment into an auditable sparse patch and technical retry queue. |
| `scripts/updater/workflow_02_apply_patch.R` | Applies a Workflow 02 patch to canonical JSONL in exact or fill-missing mode. |
| `scripts/updater/workflow_02_merge_patches.R` | Merges prior and current enrichment patches into the cumulative Workflow 02 state. |
| `scripts/updater/workflow_02_inventory_state.R` | Produces corpus-wide counts of remaining missing titles and abstracts after enrichment. |
| `scripts/updater/workflow_02_restore_state_from_zenodo.R` | Restores and checksum-verifies a previous Workflow 02 sparse state from restricted Zenodo. |
| `scripts/updater/workflow_02_archive_state_to_zenodo.R` | Archives the cumulative sparse enrichment state and lineage to restricted Zenodo. |
| `scripts/updater/workflow_02_update_zenodo_registry.R` | Registers published Workflow 02 states and writes lightweight repository pointers. |

## Inputs and methodological rules

### Authoritative upstream input

Workflow 02 consumes the authoritative Workflow 01 canonical JSONL reconstructed from the registered Workflow 01 baseline-plus-delta state.

The initial validated Workflow 02 baseline used Workflow 01 canonical SHA-256:

`f0772fb92cca9fcc676a0f77bf8b2eae0becebf60b07cb23db989d22b7cabe80`

Workflow 02 records this checksum in its durable state so enrichment provenance is bound to an exact upstream corpus.

### Eligibility

A canonical record is eligible for provider lookup only when:

- a DOI is present; and
- the canonical title and/or canonical abstract is missing.

Workflow 02 does not query records that already contain both fields.

### Existing-field protection

Workflow 02 never overwrites an already populated canonical title or abstract.

The patch builder validates that any changed title or abstract was previously missing and that no Workflow 01 identity, manifestation, DOI or unrelated record field changed.

### Provider order

Provider order is fixed:

1. Europe PMC;
2. Scopus only when metadata remain missing after Europe PMC.

This order reduces unnecessary Scopus calls while retaining Scopus as the broader fallback.

### Europe PMC matching

Europe PMC metadata are accepted only where the provider returns the exact normalised DOI requested.

Returned abstracts are subject to the title-consistency guard where a provider title and canonical title are both available.

### Scopus matching

Scopus retrieval proceeds through:

1. direct Abstract Retrieval by DOI using `view=META_ABS`;
2. if direct retrieval does not return usable metadata, Scopus Search by DOI;
3. if the search yields one compatible candidate, retrieval by EID using `META_ABS`.

EID fallback is accepted only when the resulting full Scopus record returns the exact requested DOI.

### Title-consistency guard

When an abstract is returned and both the canonical record and provider response contain titles, Jaro-Winkler title similarity must be at least 0.90.

Provider metadata below that threshold are not applied. They are recorded as quarantined conflicts.

### Retry policy

Workflow 02 records provider outcomes within each attempted record.

Successful or no-result attempts are deferred for 90 days by default before being eligible for another provider lookup. Records with a technical provider failure remain eligible for retry on the next run.

This prevents fortnightly updater runs from repeatedly querying unchanged unresolved records.

## Processing stages

### 1. Restore Workflow 01

The registered Workflow 01 pointer is restored through its full baseline and delta chain. The resulting canonical JSONL checksum is calculated and retained as Workflow 02 lineage.

### 2. Restore prior Workflow 02 state

If a previous Workflow 02 pointer is supplied, its cumulative patch is restored from restricted Zenodo and checksum-verified.

The previous patch is applied in fill-missing mode to the current Workflow 01 corpus. This means improved upstream Workflow 01 metadata take precedence over older enrichment patches.

### 3. Discover due enrichment candidates

Workflow 02 scans the canonical corpus and selects records with a DOI and missing title and/or abstract.

Records with recent non-technical enrichment attempts are deferred according to the configured recheck period.

### 4. Query Europe PMC

Europe PMC is queried first. Exact DOI equality is required before any field can be applied.

### 5. Query Scopus

Scopus is queried only for records that still lack title and/or abstract after Europe PMC.

Direct DOI retrieval is attempted first, followed by DOI search and EID retrieval where needed.

### 6. Apply verified fills and quarantine conflicts

Only missing canonical fields can be populated.

Returned abstracts are guarded by title similarity. DOI mismatch, title inconsistency or ambiguous Scopus resolution results in quarantine rather than automatic repair.

### 7. Build sparse patch

The current enrichment run is converted into one patch record per attempted canonical work.

Each patch records:

- stable `record_id`;
- input DOI;
- newly filled title and/or abstract where applicable;
- provider responsible for each applied field;
- provider outcome metadata;
- enrichment completion date;
- missing-field state after enrichment; and
- the corresponding provider audit object.

Technical provider failures are written separately to a retry queue.

### 8. Validate exact current-patch replay

The current patch is applied back to the pre-run canonical state.

The reconstructed JSONL must match the direct enrichment output exactly by SHA-256.

### 9. Merge cumulative Workflow 02 state

The newly generated patch is merged with the prior cumulative patch by stable `record_id`.

New verified field fills update that record’s sparse enrichment state without duplicating the full canonical corpus.

### 10. Validate cumulative reconstruction

The cumulative patch is applied to the pristine authoritative Workflow 01 canonical JSONL.

The result must reproduce the final enriched canonical JSONL exactly by SHA-256.

This is the principal integrity gate before publication.

### 11. Inventory residual missing metadata

Workflow 02 inventories the final enriched corpus and records:

- total canonical works;
- records with DOI;
- records missing title;
- records missing abstract;
- records missing both title and abstract.

A separate queue is written for records missing both fields.

### 12. Publish durable automated enrichment state

When publication is enabled, only the sparse automated Workflow 02 enrichment state is archived to restricted Zenodo.

The enriched canonical JSONL can therefore be reconstructed from:

```text
authoritative Workflow 01 canonical JSONL
    +
Workflow 02 cumulative enrichment patch
    =
automatically enriched canonical JSONL
```

## Provenance and documentation

Workflow 02 records, where applicable:

- exact upstream Workflow 01 canonical SHA-256;
- previous Workflow 02 lineage;
- stable canonical `record_id`;
- normalised DOI;
- missing title/abstract state before and after enrichment;
- Europe PMC response outcome;
- Scopus response outcome;
- Scopus EID where used;
- provider attempts;
- provider responsible for each applied field;
- title similarity for guarded abstract fills;
- quarantined conflict reason;
- technical-error state;
- configured recheck period;
- current patch SHA-256;
- cumulative patch record count;
- enriched canonical JSONL SHA-256;
- retry queue SHA-256;
- final inventory;
- GitHub Actions run ID;
- Zenodo record identifier and DOI;
- archive size and SHA-256;
- archive manifest SHA-256;

## Storage and archival model

### Permanent repository records

The repository stores lightweight Workflow 02 lineage and methodology:

- production and validation workflows;
- enrichment, patch, replay, inventory and archival scripts;
- this reporting document;
- `docs/enrichment/zenodo_registry.csv`; and
- one small pointer under `docs/enrichment/zenodo/` for each published Workflow 02 state.

The fully enriched canonical corpus is not committed to Git.

### Short-lived GitHub Actions artefacts

Operational state is retained temporarily for validation and debugging, including:

- current patch;
- cumulative patch;
- enrichment audit;
- retry queue;
- inventory;
- replay reports;
- Zenodo receipt.

These artefacts are not the durable source of truth.

### Durable external archive

Each accepted Workflow 02 state is deposited as a restricted Zenodo record.

The automated enrichment archive contains the cumulative sparse enrichment patch, enrichment audit, retry state, inventory and replay/provenance reports. It does not duplicate the complete Workflow 01 canonical corpus.


Each durable state is represented in `docs/enrichment/zenodo_registry.csv` and by a lightweight JSON pointer under `docs/enrichment/zenodo/`.

## Validated baseline

The first full production Workflow 02 enrichment baseline is GitHub Actions run `36137804187`.

Upstream Workflow 01:

- canonical records: 32,292;
- canonical SHA-256: `f0772fb92cca9fcc676a0f77bf8b2eae0becebf60b07cb23db989d22b7cabe80`.

Workflow 02 eligibility and enrichment:

- DOI-bearing records with missing title and/or abstract: 3,434;
- Europe PMC abstracts filled: 175;
- Europe PMC titles filled: 0;
- Scopus records attempted after Europe PMC: 3,259;
- Scopus titles filled: 25;
- Scopus abstracts filled: 1,990;
- Scopus HTTP 404 responses: 739;
- provider conflicts quarantined: 199;
- technical-error records: 0;
- attempted records still missing one or more targeted fields after lookup: 1,244.

Total verified additions:

- title fills: 25;
- abstract fills: 2,165.

Replay validation:

- current patch records: 3,434;
- current patch field conflicts: 0;
- current patch reproduced the direct enrichment output exactly;
- cumulative patch reproduced the final enriched canonical JSONL exactly.

Final corpus inventory:

- canonical records: 32,292;
- missing titles: 16;
- missing abstracts: 2,689;
- missing both title and abstract: 0.

The enriched canonical JSONL SHA-256 is:

`c88d36631512b5b30853fb3ae271db2e456b2a8b5b94925ccf0840e8f8d9156b`

The durable Workflow 02 state is stored as restricted Zenodo record `22960664`, DOI `10.5281/zenodo.22960664`.

Repository pointer:

`docs/enrichment/zenodo/run-36137804187.json`

The archived sparse state contains 3,434 cumulative patch records. The state archive SHA-256 is:

`038d62233546037b8af4c6277a07b633dfae83e62a3596c9ff6dc3026ada324a`

The archive manifest SHA-256 is:

`405d54e01a4578ca6477820ea836f1142a3ca1a57647cf3028bed04da8ed20e2`

## Validated-state handoff

Validated Workflow 02 materialisations are retained for seven days as downstream handoff caches. The durable sparse enrichment state remains authoritative. A downstream workflow may use a live materialised cache only when its checksum matches the checksum registered for the accepted Workflow 02 state; otherwise the state is reconstructed from the exact upstream Workflow 01 corpus plus the registered Workflow 02 sparse layer.

The post-Workflow-02 lean canonical checkpoint follows the same rule: a seven-day materialised lean artefact may be used directly, while the registered restricted Zenodo checkpoint provides the durable fallback.

## Downstream handoff

The Workflow 02 handoff is the automatically enriched canonical state reconstructed from:

1. the exact registered Workflow 01 canonical state; and
2. the registered Workflow 02 cumulative enrichment patch.

Any finite one-off canonical corrections applied while establishing a particular baseline are documented separately in `docs/reporting/workflow_02/AD_HOC_ACTIONS.md` and are not part of the automated enrichment methodology.


Downstream workflows must preserve the stable Workflow 01 `record_id` and source manifestations. Workflow 03 should reconstruct this exact state from the registered sparse layers and verify the resulting checksum before performing retraction surveillance. It must not rebuild bibliographic enrichment independently.

## Methods text for research reporting

> **Workflow 02: bibliographic metadata enrichment.** Canonical records with a DOI but a missing title and/or abstract were subjected to deterministic metadata enrichment. Europe PMC was queried first, with metadata accepted only where the returned DOI exactly matched the requested normalised DOI. Records remaining incomplete were queried against Scopus using direct DOI-based abstract retrieval and, where necessary, DOI search followed by EID retrieval. Existing populated canonical fields were never overwritten by the automated process. Returned abstracts were accepted only when provider and canonical titles were consistent, using a Jaro-Winkler similarity threshold of 0.90 where both titles were available; conflicting metadata were quarantined rather than applied. Automated enrichment was stored as a sparse patch keyed to stable canonical work identifiers rather than as a duplicate full corpus, and both current and cumulative patch states were replayed against the authoritative upstream corpus before archival. Provider outcomes, accepted fills, quarantined conflicts, checksums and lineage were retained for provenance, and the cumulative sparse enrichment state was replayed against the exact upstream canonical corpus before archival.

## Reporting status

Workflow 02 is considered validated when:

- the Workflow 01 canonical JSONL is consumed without a schema adapter;
- stable work identities and source manifestations remain unchanged;
- existing title, abstract and DOI values are not overwritten;
- only DOI-bearing records with missing target fields are queried;
- provider matches satisfy exact DOI and title-consistency rules;
- conflicting provider metadata are quarantined;
- technical failures are separately identifiable and retryable;
- the current sparse patch exactly reproduces the direct enrichment output;
- the cumulative patch applied to authoritative Workflow 01 exactly reproduces the final enriched canonical JSONL;
- residual missing metadata are inventoried;
- the automated sparse Workflow 02 enrichment state is deposited to restricted Zenodo;
- the final post-Workflow-02 canonical checksum is recorded;
- all Zenodo pointers and lineage are registered in the repository; and
- Workflow 03 can reconstruct the authoritative post-Workflow-02 state without another complete canonical JSONL archive.

The automated enrichment conditions were satisfied by production run `36137804187`. Baseline-specific manual correction work is documented separately in `docs/reporting/workflow_02/AD_HOC_ACTIONS.md`.

**Workflow 02 status: complete and ready for downstream Workflow 03 consumption.**
