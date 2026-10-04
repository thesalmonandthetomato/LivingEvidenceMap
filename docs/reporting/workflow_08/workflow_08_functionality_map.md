# Workflow 08: Human adjudication and final canonical assembly

## Purpose

Workflow 08 is the final decision and assembly stage before reporting. It combines the validated automated states from Workflows 03-07, applies deterministic final-routing rules, reuses compatible prior adjudications, sends only genuinely unresolved current issues to human review, and produces the definitive included-only canonical evidence base plus a separate exclusions register.

Human decisions are retained as an auditable overlay. Workflow 08 does not rewrite the archived automated W04-W07 layers.

## Current production state (4 October 2026)

The current authoritative W08 state is finalisation run **37211675882**, published as restricted Zenodo record **23138991** (DOI `10.5281/zenodo.23138991`). It supersedes Zenodo record **23020526**.

The current release partitions the **47,094-record** W01 canonical population exactly into:

- **21,493 included records** in `living_evidence_map_canonical_final.jsonl`;
- **25,601 excluded records** in `workflow08_excluded_records.csv`; and
- **137 current W08 decision issues** in the complete adjudication ledger.

The final canonical SHA-256 is:

`cb1f28a2adb3edbc368d9d10de1517d51cd43d024e449bf1f7149eb87ab77ffb`

The exclusions CSV SHA-256 is:

`0333e94685f51b979ef2ad7782ff3f7ca2791f5954cfd1be97bab843da68c2de`

The complete adjudication-ledger SHA-256 is:

`bf1ad246638ddc8d4a0362bbbf40aa5a8228cbf8e9cf75be00090314d60610dc`

The current Shiny batch was `w08-run-37207870620`. Finalisation required an exact-current-state decision for every one of the 137 issue keys before assembly could proceed. The batch was marked `consumed` only after the final state had been archived and registered.

## Current functionality map

```text
[current W01 canonical population: 47,094]
                  +
        validated W03-W07 states
                  |
                  v
       build current W08 issue index
                  |
                  +--> W05 species NONE
                  |       deterministic exclusion
                  |       no human review
                  |
                  +--> W06 geography
                  |       deterministic auto-NONE where allowed
                  |       remaining eligible cases -> review
                  |
                  +--> W07 topic QC
                          Jaccard descriptive only
                          residual coding/eligibility cases -> review
                  |
                  v
       exact issue-state fingerprints
                  |
          +-------+--------+
          |                |
          v                v
 compatible prior     new/changed current
 decisions reused     issues sent to Shiny
          |                |
          +-------+--------+
                  |
                  v
      complete current decision ledger
          (must cover every issue)
                  |
                  v
       deterministic final assembly
                  |
          +-------+--------+
          |                |
          v                v
   included canonical    exclusions register
       21,493              25,601
          |                |
          +-------+--------+
                  |
                  v
       restricted Zenodo archive
           + repository pointer
                  |
                  v
               W09
```

## Inputs

Workflow 08 restores and checksum-verifies the exact states selected for the current release:

- the post-W02 lean canonical population;
- W03 publication-status layer;
- W04 final screening layer;
- W05 deterministic species layer and match provenance;
- W06 semantic geography layer;
- W07 retained topic scores, topic-QC state and late exclusions;
- the current W08 issue index;
- compatible prior W08 decisions where their issue-state fingerprints still match; and
- newly completed human decisions from the Shiny adjudication store.

The finaliser fails closed if input identity, cardinality or decision coverage is inconsistent.

## Deterministic pre-review rules

### Species `NONE`

For current dynamic runs, W05 records with `farmed_species_codes == "NONE"` are deterministically excluded before human review.

This rule means:

- the W05 automated result is preserved unchanged for provenance;
- the record is omitted from the W08 human queue;
- any geography or topic issue for the same record is suppressed because the record is already excluded; and
- finalisation records `exclusion_reason = "species_none_deterministic_exclusion"`.

The current W05 state contains **191** such records.

Historical `species_none` decisions remain readable by the finaliser solely so older archived runs can still be reconstructed.

### Geography auto-resolution

A non-failure W06 record with raw `geography_status = UNRESOLVED` and no candidate Luna ISO3 code is deterministically materialised downstream as geography `NONE`. The raw W06 status is retained in provenance.

This rule does **not** auto-resolve:

- terminal model/API failures;
- unresolved records containing one or more candidate countries; or
- resolved assignments that still fail the current evidence-validation contract.

## Current human-review issue types

Current production W08 can generate:

- `geography_unresolved`;
- `geography_evidence_unvalidated`;
- `geography_model_failure`;
- `topic_coding_review`; and
- `zero_topic_eligibility_uncertain`.

Historical issue types such as `species_none`, `topic_extreme_disagreement` and `ontology_pathology` remain readable for backward compatibility but are not all current production routes.

Mean pairwise topic Jaccard is descriptive reproducibility/QC information and is **not** a W08 human-review gate.

## Geography decision contract

For `geography_unresolved` and `geography_evidence_unvalidated`, allowed outcomes are:

- `accept_model`;
- `override_country_set`;
- `assign_none`; or
- `exclude_record`.

For `geography_model_failure`, allowed outcomes are:

- `assign_country_set`;
- `assign_none`; or
- `exclude_record`.

`accept_model` materialises Luna's proposed country set as final `RESOLVED` geography. It does not preserve raw `UNRESOLVED` as the analytical result.

`exclude_record` is a record-level eligibility decision discovered during geography review. Finalisation records it as a Workflow 08 exclusion while retaining the geography review provenance.

Legacy `assign_country_set` decisions for older unresolved/evidence-validation issues remain readable as a backward-compatible alias of `override_country_set`.

## Topic decision contract

### `topic_coding_review`

Allowed outcomes are:

- `accept_retained_topics`;
- `replace_topic_set`;
- `no_code`; or
- `exclude_record`.

### `zero_topic_eligibility_uncertain`

Allowed outcomes are:

- `assign_topic_set`;
- `include_uncoded`; or
- `exclude_record`.

Raw W07 model assignments, retained pathways and pass-support values remain preserved for audit.

## Record-level Shiny review

The Shiny interface uses one row per unique record, with an `issues` array containing every current human-review issue for that record. All issues for the record are shown together and all must have valid decisions before the record is complete.

The queue is checksum-locked. Decisions record:

- stable `review_key`;
- `record_id`;
- `issue_type`;
- exact `issue_state_sha256`;
- chosen outcome;
- final value where applicable;
- reviewer;
- resolution timestamp; and
- queue SHA-256.

The backend verifies the live queue SHA before accepting a save, so a stale browser session cannot silently write against a replaced W08 queue.

## Decision reuse

Prior W08 decisions are reusable only when both the stable review key and exact current issue-state fingerprint match. A decision is not reused merely because the record or issue type has appeared previously.

The resume finaliser combines:

1. compatible decisions already present in the immutable stopped-run state;
2. cumulative historical Shiny decision history; and
3. fresh decisions from the active batch.

Later/current decisions take precedence, but only when the exact issue-state fingerprint matches.

Finalisation stops unless the resulting ledger covers the entire current issue index exactly.

## Final assembly

Workflow 08 assembles the full disposition state from the upstream canonical record plus W03-W07 layers and the complete W08 decision ledger, then partitions it into:

1. an included-only canonical JSONL; and
2. a separate exclusions CSV.

The canonical JSONL retains the complete upstream annotation/provenance objects required for downstream reporting and dashboard use. The exclusions file preserves bibliographic identifiers and final exclusion stage/reason.

The current archive uses annotation-preservation contract:

`lossless-upstream-handoff-v2`

## Durable archive

The current authoritative restricted Zenodo record is:

- record: **23138991**
- DOI: `10.5281/zenodo.23138991`
- source GitHub run: **37211675882**
- visibility: restricted

It contains:

1. `living_evidence_map_canonical_final.jsonl`;
2. `workflow08_excluded_records.csv`;
3. `workflow08_adjudication_ledger.jsonl`; and
4. `workflow08_final_manifest.json`.

Repository lineage is recorded in:

- `docs/workflow08/zenodo/run-37211675882.json`; and
- `docs/workflow08/zenodo_registry.csv`.

Zenodo record **23020526** is now superseded and must not be selected as the current W08 handoff.

## Downstream handoff

Workflow 09 must resolve the single `authoritative` row in the W08 registry, restore the corresponding pointer and verify:

- pointer status is `published`;
- workflow is `08`;
- canonical record count;
- final canonical SHA-256;
- archive/file checksum; and
- the lossless annotation-preservation contract.

For the current release, W09 therefore consumes run **37211675882**, not a historical W08 pointer.

## Live pipeline-status handoff

A final published W08 state now updates `docs/current_run/current_run_status.json` and the Shiny `pipeline_run_status` sheet **inside the W08 production/resume workflow itself** after registration.

The current status after W08 is:

- W00-W08 complete;
- W10/dashboard position active/pending next;
- status label: `Final adjudication complete; awaiting dashboard build`.

This direct update is required because a registry commit made by a workflow using the repository `GITHUB_TOKEN` does not trigger another push-based status workflow. The Shiny application polls the status sheet every 30 seconds, so once the backend row exists the top progress display updates without republishing the app.

## Historical baseline provenance

The September 2026 baseline W08 release used an 811-issue offline adjudication over a 32,292-record source population and ultimately produced 19,117 included records in Zenodo record **23020526**. That archive remains an important immutable historical release and validation record, but it is no longer authoritative for the current living map.

Historical counts, offline-workbook decisions and earlier partition corrections must therefore be interpreted as provenance for that baseline release rather than as the current W08 operating state.

## Methods text for research reporting

> **Workflow 08: human adjudication and final assembly.** Automated species, geography and topic layers were combined with deterministic final-routing rules before human review. Records for which Workflow 05 identified no eligible focal species were excluded deterministically without human review, and non-failure unresolved geography records without a candidate country were deterministically assigned no geography while preserving the raw model output. Remaining current review issues were represented in a checksum-locked record-level Shiny queue. Previously adjudicated issues were reused only when their stable review key and exact issue-state fingerprint matched the current state. Human geography and topic decisions were retained as a separate adjudication overlay and the workflow failed closed unless every current issue had a valid decision. Final assembly partitioned the complete source population into an included-only canonical JSONL and a separate exclusions register, retained upstream annotation provenance losslessly, checksum-validated all outputs and archived the definitive state in a restricted Zenodo record.

## Reporting status

**COMPLETE and validated for the current release.** Run **37211675882** produced the authoritative W08 state: **47,094 source records = 21,493 included + 25,601 excluded**, with **137/137 current decision issues resolved**. The authoritative archive is Zenodo record **23138991**, DOI `10.5281/zenodo.23138991`.
