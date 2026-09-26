# Workflow 04: relevance screening

## Purpose

Workflow 04 screens the publication-status-eligible canonical corpus from Workflow 03 for relevance to the Living Evidence Map of commercial aquaculture of Atlantic salmon, specified Pacific salmon species and rainbow trout.

The workflow applies a high-sensitivity title/abstract screening rule using repeated independent model classifications. Two independent Luna passes are run for every eligible record. Records for which the first two passes disagree, return `uncertain`, or encounter a technical failure receive a third independent pass. A substantive retain/exclude decision requires at least two matching substantive votes. Records that still lack two matching substantive votes are routed to human review rather than being coerced into a model decision.

This document serves two purposes:

1. as a methodological guide to the repository implementation; and
2. as source text for reporting Workflow 04 in a research paper.

Operational recoveries, historical-state reuse and one-off adjudication actions used while establishing the validated baseline are intentionally excluded from this workflow description. They are documented separately in `docs/reporting/workflow_04/AD_HOC_ACTIONS.md`.

## Functionality map

```text
Workflow 03 lean canonical corpus
+ publication-status layer
          |
          v
exclude records flagged by Workflow 03
as retracted or withdrawn
          |
          v
validate stable record_id coverage
+ immutable W04 screening prompt
          |
          v
deterministic record sharding
          |
          +-----------------------------+
          |                             |
          v                             v
    Luna pass 1                   Luna pass 2
          |                             |
          +-------------+---------------+
                        |
                        v
       compare decisions / technical state
                        |
             +----------+----------+
             |                     |
       matching substantive      disagreement,
       retain/exclude            uncertain, or failure
             |                     |
             |                     v
             |               Luna pass 3
             |                     |
             +----------+----------+
                        |
                        v
              2-of-2 / 2-of-3 rule
                        |
             +----------+----------+
             |                     |
        RETAIN / EXCLUDE       no two matching
             |                 substantive votes
             |                     |
             |                     v
             |                 human review
             |                     |
             +----------+----------+
                        |
                        v
          final Workflow 04 screening layer
          + included record_id set
          + excluded record_id set
                        |
                        v
                     Workflow 05
              species/geography annotation
```

## Components

| Component | Function |
|---|---|
| `.github/workflows/workflow_04_consensus.yml` | Production controller for restoring authoritative Workflow 03 inputs, validating eligibility, running deterministic shards, and merging the consensus layer. |
| `scripts/updater/workflow_04_luna_consensus.R` | Applies the immutable relevance-screening prompt, performs two independent Luna passes, triggers a third pass for disagreement/uncertainty/technical failure, and assigns 2-of-2 or 2-of-3 consensus decisions. |
| `scripts/updater/workflow_04_merge_consensus.R` | Merges shard outputs and validates complete, unique record coverage, prompt identity and allowed decision states. |
| `scripts/updater/workflow_04_agreement_audit.R` | Reproducibly calculates model-pass agreement and comparison statistics for reporting and validation. |
| `docs/reporting/workflow_04/workflow_04_functionality_map.md` | Methodological and reporting description of the production workflow. |
| `docs/reporting/workflow_04/AD_HOC_ACTIONS.md` | Separate record of non-routine actions used while establishing the validated baseline; these actions are not part of the production workflow definition. |

## Inputs and methodological rules

### Authoritative input state

Workflow 04 consumes two authoritative Workflow 03 outputs:

1. the lean canonical work-level JSONL, retaining stable canonical `record_id` values and lightweight manifestation references; and
2. the sparse Workflow 03 publication-status layer.

The two inputs must contain the same canonical work identities. Workflow 04 does not regenerate bibliographic enrichment, deduplication or publication-status inference.

Records with `exclude_from_workflow04=true` are removed before relevance screening. Under Workflow 03 this flag is set only for records classified as `retracted` or `withdrawn`.

### Screening model

The production screening model is:

`gpt-5.6-luna`

Each pass is an independent API classification using the same record metadata and immutable system prompt.

### Immutable screening prompt

The production prompt version is:

`workflow04-v3-salmon-lice-clarification`

The required SHA-256 is:

`ab71cad800996f2aea4cf1313c3ab749017f01094946830671f2f579a4710f69`

The screening implementation calculates the prompt checksum at runtime and fails if it differs from the required checksum.

### Eligible species and contexts

The relevance criteria include:

- Atlantic salmon (`Salmo salar`);
- Chinook salmon (`Oncorhynchus tshawytscha`);
- coho salmon (`Oncorhynchus kisutch`);
- sockeye salmon (`Oncorhynchus nerka`);
- chum salmon (`Oncorhynchus keta`);
- pink salmon (`Oncorhynchus gorbuscha`);
- masu salmon (`Oncorhynchus masou`);
- rainbow trout (`Oncorhynchus mykiss`, including historical synonyms); and
- unspecified salmon where the salmon-farming context itself establishes relevance.

A record must establish both:

1. an eligible species or a relevant explicit salmon-farming context; and
2. commercial aquaculture relevance.

Commercial aquaculture relevance includes farmed production, products, processes, infrastructure, inputs, consequences and impacts. Evidence may come from title, abstract, keywords, source title, or explicitly supplied affiliation/funding metadata.

The prompt contains explicit rules for:

- impacts of salmon farming where the measured organism is not itself an eligible species;
- salmon lice in an aquaculture context;
- fishmeal where an eligible species is also identified;
- wild-population studies linked to salmon aquaculture;
- farmed products and processing;
- hatchery, stock-enhancement and ocean-ranching exclusions;
- experimental cages/pens that do not themselves establish commercial farming;
- generic `salmonid` terminology; and
- non-standard document types and corrigenda.

### Decision vocabulary

Each model pass must return exactly one of:

- `retain`;
- `exclude`;
- `uncertain`.

The response must also contain one concise reason grounded in the supplied bibliographic metadata.

### Consensus rule

Every eligible record receives pass 1 and pass 2.

A third pass is triggered when:

- pass 1 and pass 2 disagree;
- either pass returns `uncertain`; or
- either pass encounters a technical failure.

Only non-failed `retain` and `exclude` votes count as substantive votes.

Final model consensus is:

- `retain` when at least two substantive votes are `retain`;
- `exclude` when at least two substantive votes are `exclude`;
- `uncertain` otherwise.

An unresolved `uncertain` result is a human-review state, not an exclusion.

### Sharding

Records are sorted by stable `record_id` and allocated deterministically across shards. Sharding changes execution granularity only; it does not change screening logic or record assignment.

## Processing modes or stages

### 1. Restore and validate Workflow 03 inputs

The production controller restores the authoritative lean canonical corpus and publication-status layer. It validates record counts, stable `record_id` uniqueness, identity concordance and the number of Workflow 03 exclusions before screening begins.

### 2. Remove Workflow 03-ineligible publication states

Records marked as retracted or withdrawn are not submitted to relevance screening.

No other publication-status category is excluded at this stage.

### 3. Run two independent Luna passes

Every W03-eligible record is screened twice using the same immutable prompt and supplied bibliographic metadata.

Pass results are persisted independently and include the structured decision and concise bibliographic reason.

### 4. Identify the third-pass queue

The workflow compares pass 1 and pass 2.

Any disagreement, `uncertain` result or technical failure routes the record to pass 3. Records with two matching substantive, non-failed votes do not require a third call.

### 5. Run conditional third pass

The third pass uses the same model, prompt, metadata representation and structured response schema as passes 1 and 2.

It is an additional independent classification, not an adjudicator with access to the preceding votes.

### 6. Derive model consensus

The workflow applies the two-matching-substantive-votes rule.

Consensus provenance records whether the result was resolved by 2-of-2 agreement, 2-of-3 agreement, or remained unresolved.

### 7. Human review of unresolved cases

Records without two matching substantive votes are passed to human review.

Human review is a downstream adjudication of the unresolved screening state. The model workflow must not silently convert unresolved cases into retain or exclude decisions.

### 8. Validate the final screening layer

Before handoff, Workflow 04 requires:

- one final screening record for every W03-eligible `record_id`;
- no duplicate `record_id` values;
- only allowed decision states;
- the expected immutable prompt SHA for model-derived records; and
- no unresolved records in a finalised handoff.

The finalised layer is partitioned into retained and excluded stable record-ID sets.

## Provenance and documentation

Workflow 04 records, where applicable:

- stable canonical `record_id`;
- screening pass number;
- pass decision;
- bibliographic reason supplied by the model;
- technical-failure state and error message;
- requested model;
- model returned by the API;
- API response identifier;
- token-usage metadata;
- prompt version;
- prompt SHA-256;
- screening timestamp;
- all substantive votes used for consensus;
- retain and exclude vote counts;
- whether a third pass was required;
- consensus state (`2_of_2`, `2_of_3`, or unresolved);
- final relevance-screening decision;
- human-review requirement where applicable;
- total retained/excluded/unresolved counts; and
- GitHub Actions run identifiers and artefact checksums.

Agreement statistics are derived from the unmodified pass outputs before any human adjudication is applied.

## Storage and archival model

### Permanent repository records

GitHub retains lightweight methodological and reporting material, including:

- Workflow 04 R scripts;
- GitHub Actions workflow definitions;
- the immutable prompt definition and checksum;
- this functionality/methods report;
- the separate ad hoc actions report;
- the reproducible agreement-audit script; and
- machine-readable agreement summaries used for Workflow 09 reporting.

The complete screened corpus should not be maintained in Git as a duplicated full canonical dataset.

### Short-lived GitHub Actions artefacts

Operational Actions artefacts may include:

- restored Workflow 04 input;
- per-shard pass 1, pass 2 and pass 3 outputs;
- per-shard consensus layers;
- merged consensus layer;
- final screening layer;
- included and excluded record-ID lists; and
- included canonical records for downstream handoff.

Actions artefacts are execution, validation and recovery aids rather than the preferred durable long-term source of truth.

### Durable external archive

The final Workflow 04 screening state should be retained as a durable, checksum-addressed checkpoint with upstream Workflow 03 lineage and enough sparse decision/provenance state to reconstruct the authoritative retained set without repeating model screening.

The durable checkpoint should record:

- upstream canonical and Workflow 03 state identifiers/checksums;
- prompt version and SHA-256;
- model and decision-rule version;
- final screening-layer checksum;
- included/excluded counts;
- retained record-ID checksum;
- source GitHub Actions run; and
- archive checksum/manifest.

The validated final screening state is archived as restricted Zenodo record `22973914`, DOI `10.5281/zenodo.22973914`. The repository pointer is `docs/workflow04/zenodo/run-36227737500.json`.

## Validated baseline

The validated Workflow 04 baseline contains:

- Workflow 03 canonical works: 32,292;
- excluded before W04 by publication status: 9;
- W04-eligible records: 32,283;
- final retained records: 19,407;
- final excluded records: 12,876;
- final unresolved records: 0;
- final inclusion rate: 60.12%.

The final baseline was validated in GitHub Actions run `36227737500`.

### Screening reliability

The primary model-consistency statistics, calculated from original model outputs before human or historical adjudication altered any final decision, were:

- Luna pass 1 vs pass 2 across all 32,283 records: 96.31% exact agreement, Cohen's κ = 0.925;
- Luna pass 1 vs pass 2 where both passes were substantive retain/exclude decisions: 98.32% agreement, Cohen's κ = 0.964;
- final Luna consensus vs 21,950 comparable previous safe screening decisions: 96.79% agreement, Cohen's κ = 0.922; and
- three-rater agreement across historical screening, Luna pass 1 and Luna pass 2 for 21,798 records with three substantive decisions: Fleiss' κ = 0.935, with 96.01% unanimous agreement.

These statistics describe screening agreement and consistency. The previous screening decisions are a historical comparator, not an independent gold standard.

The selectively triggered third-pass subset is not used as an overall performance estimate because it is deliberately enriched for difficult or unstable cases.

## Validated-state handoff

The final Workflow 04 screening layer and materialised retained subset are exposed as a seven-day GitHub Actions handoff cache for Workflow 05. The restricted Zenodo screening checkpoint remains authoritative. Workflow 05 may use the live cache only after verifying the registered screening-layer and retained-ID checksums; if the cache is unavailable or fails verification, it must restore the W04 layer from Zenodo and rematerialise the retained corpus from the authoritative upstream canonical state.

The 90-day per-shard model outputs used to protect costly screening work are recovery checkpoints, not downstream handoff caches, and are retained under the separate costly-work checkpoint policy.

## Downstream handoff

The Workflow 04 downstream handoff is the retained set of stable canonical `record_id` values together with the corresponding Workflow 03 lean canonical records and the final screening provenance layer.

For the validated baseline, 19,407 records are passed to Workflow 05.

Workflow 05 must preserve the canonical `record_id` and use the Workflow 04 retained set as an inclusion mask. It must not rerun relevance screening or reinterpret Workflow 04 publication eligibility.

The intended next stage is deterministic species and geography annotation/reconciliation, followed by later topic coding.

## Methods text for research reporting

> **Workflow 04: relevance screening.** Records remaining eligible after publication-status filtering were screened for relevance to commercial aquaculture of Atlantic salmon, specified Pacific salmon species and rainbow trout using repeated independent language-model classifications. Each record was screened twice using an immutable high-sensitivity eligibility prompt applied to bibliographic metadata. Records for which the first two classifications disagreed, returned an uncertain classification or encountered a technical failure received a third independent classification. A record was classified as retained or excluded when at least two substantive classifications agreed; records without two matching substantive votes were routed to human adjudication. Screening decisions required evidence of both an eligible species or explicit relevant salmon-farming context and commercial aquaculture relevance, with predefined rules for wild populations, hatchery and stock-enhancement studies, salmon lice, fishmeal, farm impacts, experimental containment and product/processing studies. Stable canonical record identifiers, individual pass decisions, reasons, model/prompt versions and final consensus provenance were retained for reproducibility.

## Reporting status

Workflow 04 is considered methodologically complete when:

- the authoritative Workflow 03 lean canonical and publication-status states are restored and identity-validated;
- records flagged by Workflow 03 as retracted or withdrawn are excluded before screening;
- the immutable screening prompt passes its SHA-256 integrity check;
- every W03-eligible record receives two independent Luna classifications;
- every disagreement, uncertain result or technical failure receives a third pass;
- model consensus is derived only from two matching substantive votes;
- unresolved consensus cases are routed to human adjudication rather than coerced;
- every W03-eligible stable `record_id` has exactly one final retain/exclude decision before downstream handoff;
- individual pass and final-decision provenance are retained;
- the final retained and excluded sets are count- and identity-validated; and
- Workflow 05 can consume the retained stable record-ID set without rerunning relevance screening.

These screening and validation conditions are satisfied for the current baseline: 19,407 records are retained, 12,876 excluded and none unresolved.

The durable screening checkpoint is published as restricted Zenodo record `22973914`, DOI `10.5281/zenodo.22973914`.

The archived final screening-layer SHA-256 is:

`fcdfa0ed6c3ed37f0e355fdd13f5843aa4f6dc2224603e68ead00c7aeafa1f6b`

The retained record-ID set SHA-256 is:

`285d3e7d4d00a8c090e4cc6a832b7184f0dbfff97653aeb9bb15194990b4574e`

The excluded record-ID set SHA-256 is:

`712d5ab93871565b6eaec4f1ee4dcefa40c5d740b06c14a4158009fafea538fe`

**Workflow 04 status: complete, durably archived and ready for Workflow 05 consumption.**
