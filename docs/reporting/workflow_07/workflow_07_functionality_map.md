# Workflow 07: three-pass topic coding and topic-quality control

## Purpose

Workflow 07 assigns substantive topic pathways to records retained after Workflow 06 using three independent GPT-5.6 Luna classifications against a frozen hierarchical ontology.

Its methodological purpose is to produce a reproducible multi-label topic layer while preserving model disagreement rather than collapsing it prematurely. Each topic assignment retains the number of independent model passes supporting it. Workflow 07 then applies deterministic retention rules, checks zero-topic records for residual relevance-screening problems, and routes only defined residual uncertainties to Workflow 08.

Workflow 07 does not overwrite the historical Workflow 04 screening decision. Late exclusions identified through zero-topic quality control are recorded as a downstream screening action and applied during final post-W08 assembly.

This document is intended to serve two purposes:

1. as a methodological guide to the repository implementation; and
2. as source text for reporting the workflow in a research paper.

## Functionality map

```text
[Workflow 06 retained records]
            |
            v
      [title + abstract]
            |
            v
 [three independent Luna passes]
       A       B       C
        \      |      /
         \     |     /
          v    v    v
     [union of topic pathways]
            |
            v
 [1/3, 2/3, 3/3 support scores]
            |
            +-------------------------------+
            |                               |
            v                               v
   [one or more topics]                [zero topics]
            |                               |
            v                               v
 [deterministic retention]       [targeted eligibility rescreen]
 - ontology fallback pruning         2 Luna passes
 - complete star tiers               3rd only if needed
 - soft maximum 10                   |
            |                         +-----------+-----------+
            |                         |           |           |
            |                      INCLUDE     EXCLUDE    UNCERTAIN
            |                         |           |           |
            |                         v           v           v
            |                 included but   late auto-     W08 human
            |                    uncoded       exclude       review
            |
            v
 [three-pass disagreement QC]
 mean pairwise Jaccard < 0.20
            |
      +-----+-----+
      |           |
     no          yes
      |           |
      v           v
 final topic   W08 human
    layer       review
      |
      v
[Workflow 08 consolidated adjudication]
```

## Components

| Component | Function |
|---|---|
| `.github/workflows/workflow_07_topic_coding.yml` | Production controller for input restoration, three-pass topic coding, recovery, merging, zero-topic eligibility rescreening, final deterministic retention, QC and Workflow 08 routing. |
| `R/run_topic_three_luna_production.R` | Runs three independent Luna topic-classification passes, validates responses, preserves pass-level roles/reasons and aggregates pathway support. |
| `data/reference/topic_ontology_v3_6.csv` | Frozen v3.6 topic ontology used for production classification and deterministic fallback/supersession rules. |
| `data/reference/topic_system_prompt_v3_6.txt` | Frozen production topic-coding prompt. |
| `scripts/reporting/workflow07_merge_recalled_fresh_topics.R` | Merges reusable historical three-pass topic scores with newly coded records and validates the 19,407-record topic handoff. |
| `scripts/reporting/workflow07_zero_topic_targeted_rescreen.R` | Targeted eligibility re-screener for records receiving zero topic assignments. |
| `scripts/reporting/workflow07_zero_topic_targeted_rescreen_merge.R` | Merges zero-topic rescreen shards and applies the final include/exclude/uncertain routing policy. |
| `scripts/reporting/workflow07_apply_retention_and_review_rules.R` | Applies ontology fallback pruning, complete-star-tier retention, disagreement QC, zero-topic routing and final Workflow 08 flagging. |
| `.github/workflows/workflow07_finalisation_validation.yml` | Cheap validation workflow that exercises the final routing rules against preserved production outputs without repeating topic-model calls. |
| `docs/reporting/workflow_07/AD_HOC_ACTIONS.md` | Records baseline-establishment checks and diagnostic analyses that are not part of the permanent production method. |

## Inputs and methodological rules

### Authoritative input population

The current validated baseline contains **19,407 records** retained after Workflow 04 and handed through Workflows 05 and 06 under stable canonical `record_id`.

Workflow 07 supports two input modes:

- `recall_uncoded`: reuse validated historical three-pass topic scores where available and classify only records without reusable coding;
- `workflow06_all`: classify the entire accepted Workflow 06 population from title and abstract.

For the current baseline, the recall audit identified:

- **12,297** records with reusable historical three-pass topic scores;
- **7,110** records requiring fresh classification.

### Frozen topic ontology and prompt

Production classification uses:

- ontology: `data/reference/topic_ontology_v3_6.csv`;
- ontology SHA-256:  
  `5d78959f86d40f200f7dc7c3184a2d5ab61fd89d1450be7fbff39c2578246a43`;
- system prompt: `data/reference/topic_system_prompt_v3_6.txt`;
- prompt SHA-256:  
  `f038a0c04a4a897ee806b36912bb3bf22a7d80040100489cf5a8a3659e56bec0`.

The ontology and prompt are checksum-validated before production coding.

### Three-pass coding rule

Each record receives three independent GPT-5.6 Luna classifications using title and abstract.

Every topic pathway returned by at least one pass is preserved. Support is represented as:

- 1/3 passes = ★;
- 2/3 passes = ★★;
- 3/3 passes = ★★★.

The individual pass-level role and reason fields are also retained. A lower-support topic is not deleted merely because another model pass did not return it.

### Records with missing abstracts

Records are not excluded from topic coding merely because an abstract is missing. If a title alone provides sufficient evidence for a topic, the topic may be assigned.

A record may therefore remain included while receiving zero topic codes when the available title/abstract metadata do not support a sufficiently specific ontology assignment. The current baseline demonstrated and manually checked this limitation. Such records are explicitly retained as **included but uncoded** after passing the targeted zero-topic eligibility rescreen.

### General/fallback-code pruning

Raw model assignments are always preserved.

For analytical use, documented ontology fallback/general codes are marked `retained_for_analysis = false` when a more specific assigned pathway supersedes them. The current explicit v3.6 rules include:

- `V3_001` general environmental issues when specific environmental pathways are present;
- `V3_052` general social issues when specific People and society pathways are present;
- `V3_071` general product issues when specific Product pathways are present;
- `V3_088` general fish health when a more specific Fish health pathway is present;
- `V3_120` other diseases - general when `V3_121`, `V3_122` or `V3_123` is present.

The raw assignment remains available with an explicit non-retention reason.

### High-topic retention rule

For records with more than ten raw topic assignments:

1. documented general/fallback codes are pruned from the analytical layer where superseded;
2. remaining pathways are ranked by support: ★★★, then ★★, then ★;
3. complete support tiers are retained while the total remains at or below ten;
4. if the highest-support tier itself contains more than ten tied pathways, the complete tied tier is retained;
5. no arbitrary within-tier tie-break is used.

The rule is therefore a **soft maximum of ten**, not a hard truncation.

The current baseline contains **51 records with more than ten raw topic assignments**. These are resolved automatically by this rule and are not sent to human review merely because of topic count.

### Three-pass disagreement rule

For each record with topic assignments, the sets returned by passes A, B and C are compared using pairwise Jaccard similarity:

`J(A,B) = |A intersection B| / |A union B|`

The three pairwise values are averaged.

Records with **mean pairwise Jaccard < 0.20** are flagged for Workflow 08 human topic adjudication.

The current baseline contains **103** such records.

A high topic count, absence of a ★★★ topic, or ordinary model disagreement does not independently trigger human review.

### Zero-topic eligibility re-screen

Receiving zero topic assignments after three independent topic passes is treated as a quality-control signal because it may indicate either:

- a genuinely eligible record whose available metadata do not support a specific topic;
- a record that passed relevance screening despite insufficient linkage to eligible salmon/rainbow-trout farming; or
- unresolved eligibility from sparse or ambiguous metadata.

Zero-topic records therefore undergo a targeted relevance re-screen before final Workflow 08 flagging.

The re-screener receives:

- title;
- abstract; and
- the explicit contextual fact that three independent topic-coding passes returned zero topics.

It does **not** attempt a fourth topic-coding pass.

The decision vocabulary is:

- `include`: sufficient evidence of linkage to eligible commercial salmon/rainbow-trout farming;
- `exclude`: insufficient substantive farming linkage or a clearly ineligible context;
- `uncertain`: supplied metadata are insufficient or contradictory.

Two independent Luna passes are run for every zero-topic record. A third pass is used only where the first two disagree, return uncertain, or fail technically.

Final routing is:

- consensus `include` -> retain as **included but uncoded**;
- consensus `exclude` -> record a **late automatic exclusion**;
- unresolved `uncertain` -> Workflow 08 human eligibility adjudication.

The zero-topic re-screen does not rewrite Workflow 04. Original W04 decisions remain preserved as historical provenance.

### Semantic/ontology pathology

Human escalation is additionally permitted for an assignment that remains structurally or semantically incompatible with the frozen ontology after deterministic fallback rules have been applied.

This category is deliberately narrow. Unusual multidisciplinary combinations or assignment to many top-level branches are not, by themselves, ontology pathologies.

## Processing modes or stages

### 1. Restore or construct the topic-coding queue

In `recall_uncoded` mode, Workflow 07 restores the validated recall audit and builds the fresh queue of records without reusable three-pass coding.

In `workflow06_all` mode, title and abstract are restored from the Workflow 06 handoff for the complete input population.

Stable `record_id` values are required and duplicate IDs are rejected.

### 2. Run three independent Luna passes

The production classifier uses the OpenAI Batch API in recoverable chunks. Each record is classified independently in passes A, B and C against the same frozen ontology and prompt.

Batch submission identifiers are persisted before polling. Completed chunks are validated and checkpointed so failed or interrupted runs do not resubmit already completed expensive model work.

### 3. Aggregate pathway support

The union of all pathways returned across the three passes is constructed per record.

For each record-pathway pair, Workflow 07 stores:

- pathway ID and hierarchy path;
- support count 1-3;
- star representation;
- role returned by each pass;
- reason returned by each pass.

### 4. Merge recalled and fresh topic coding

For the bootstrap baseline, the 12,297 recalled records and 7,110 freshly classified records are merged into one 19,407-record handoff.

The validated baseline contains **54,720 unique record-pathway assignments** before analytical retention filtering:

- **7,828** ★ assignments;
- **6,963** ★★ assignments;
- **39,929** ★★★ assignments.

### 5. Identify and re-screen zero-topic records

Records absent from the pathway-score table are explicitly identified as zero-topic records.

For the current baseline, **358 records** received zero topic assignments:

- 147 recalled records;
- 211 freshly coded records.

The targeted eligibility re-screen of these 358 records returned:

- **217 include**;
- **123 exclude**;
- **18 uncertain**.

The 217 included records remain in the evidence map as **included but uncoded**. The 123 excludes are recorded as late automatic exclusions. The 18 uncertain records proceed to Workflow 08.

### 6. Apply analytical topic-retention rules

Raw topic assignments remain immutable.

The analytical layer adds:

- `retained_for_analysis`;
- `retention_basis`;
- `topic_count_raw`;
- `topic_count_after_general_pruning`;
- `topic_count_retained`.

High-topic records are processed under the documented complete-tier soft-cap rule.

### 7. Calculate disagreement and final Workflow 08 flags

Mean pairwise Jaccard is calculated from the three pass-specific topic sets.

Current W07 topic-related human escalation consists of:

- **103** records with mean pairwise Jaccard < 0.20;
- **18** zero-topic records remaining eligibility-uncertain after targeted consensus re-screen.

These groups are mutually exclusive by construction, giving **121 Workflow 07 records for human adjudication** before any future structural or ontology-pathology exceptions.

### 8. Produce late exclusions and included-uncoded outputs

The final QC layer separately emits:

- late automatic exclusions;
- included-but-uncoded records;
- Workflow 08 human-review records;
- high-topic automated-QC records;
- retained analytical topic scores;
- record-level QC status.

This separation allows final post-W08 assembly to preserve historical workflow provenance.

## Provenance and documentation

Workflow 07 records, where applicable:

- stable canonical `record_id`;
- input mode and source run identifiers;
- ontology path and SHA-256;
- system-prompt path and SHA-256;
- model;
- pass identifier;
- batch/file/response identifiers;
- model role and reason;
- pathway ID and hierarchy;
- support count and star representation;
- raw and retained topic counts;
- analytical retention status and reason;
- pairwise-disagreement metric;
- zero-topic status;
- zero-topic eligibility-rescreen votes and consensus decision;
- late screening action;
- Workflow 08 routing reason;
- technical-failure state;
- run/commit identity.

Current validated baseline lineage:

- topic recall audit: run **36252255299**;
- successful fresh three-pass production and merged handoff: run **36264955447**;
- production commit:  
  `2ffa57dfa5afc2f024e1dffc6952d609e78c4705`;
- zero-topic deterministic diagnostic check: run **36304195833**;
- zero-topic targeted eligibility rescreen: run **36304758204**.

The deterministic zero-topic lexical check was used during method development only. Its categories were tested manually and were not adopted as the permanent eligibility decision rule.

The successful production handoff artifact from run 36264955447 is:

`workflow07-topic-handoff-36264955447`

with SHA-256:

`e91b7382346d17924d2a6e6862a708a3cd89ec73dc148b9960b228ce5c150f77`.

## Storage and archival model

### Permanent repository records

GitHub retains:

- the production workflow controller;
- the frozen ontology and prompt;
- three-pass production classifier;
- recall/fresh merger;
- zero-topic targeted re-screener;
- zero-topic consensus merger;
- deterministic retention and review-routing implementation;
- validation workflow;
- this methodological report; and
- the separate ad hoc/baseline-establishment record.

Large record-level topic outputs are not committed to Git.

### Short-lived GitHub Actions artefacts

Workflow 07 stores:

- immutable input queues;
- submitted batch state;
- validated pass/chunk checkpoints;
- merged raw topic scores;
- zero-topic rescreen shards;
- merged zero-topic rescreen decisions;
- final analytical/QC outputs.

Production and recovery artifacts are retained for 90 days. Completed model outputs are reused rather than regenerated when only downstream merge or QC logic changes.

### Durable external archive

Workflow 07 does not currently create an independent Zenodo checkpoint.

This is deliberate: W07 identifies late relevance exclusions and unresolved records that are adjudicated in Workflow 08. The final durable consolidated record state is therefore archived after W08/final assembly rather than treating the pre-adjudication W07 population as the definitive corpus.

The repository nevertheless permanently preserves the frozen ontology, prompt, processing rules and run identifiers required to reconstruct the W07 layer from the retained execution artifacts during the active pipeline cycle.

## Downstream handoff

Workflow 08 receives the validated W07 outputs keyed by stable `record_id`.

For the current baseline:

- **123** zero-topic records are handed forward as late automatic exclusions and do not require human review;
- **217** zero-topic records are retained as included but uncoded and do not require human topic adjudication solely because they lack a code;
- **18** zero-topic records require human eligibility adjudication;
- **103** coded records require human topic adjudication because mean pairwise Jaccard is below 0.20;
- high-topic records are resolved deterministically and are not escalated solely because they contain more than ten raw assignments.

Workflow 08 records human decisions as a separate adjudication layer. W07 does not alter the historical W04 screening layer or discard raw topic-model outputs.

Final post-W08 assembly combines the canonical bibliographic record with the preserved W04-W07 automated layers, late automatic exclusions and W08 human decisions.

## Methods text for research reporting

> **Workflow 07: topic coding and quality control.** Records were classified against a frozen hierarchical topic ontology using three independent GPT-5.6 Luna passes based on title and abstract. The union of returned pathways was retained, with model consistency represented by one, two or three stars corresponding to support from one, two or three passes. Raw assignments were preserved while an analytical retention layer removed documented general fallback codes when more specific pathways were present and applied a soft maximum of ten topics by retaining complete model-support tiers without arbitrary tie-breaking. Agreement among the three pass-specific topic sets was assessed using mean pairwise Jaccard similarity; records below 0.20 were routed to human adjudication. Records receiving zero topic assignments underwent a separate targeted eligibility re-screen rather than a fourth topic-coding pass. Consensus-eligible records were retained as included but uncoded, consensus-ineligible records were recorded as late exclusions, and unresolved records were routed to human adjudication. Original screening and raw topic outputs were retained for provenance.

## Reporting status

Workflow 07 is considered complete and validated when:

- the Workflow 06 input identity is preserved;
- the v3.6 ontology and topic prompt are checksum-locked;
- each newly coded record receives three independent validated topic classifications;
- recalled and fresh three-pass results are merged without duplicate record-pathway pairs;
- raw model assignments and pass-level provenance are retained;
- analytical general-code pruning and soft-cap rules are deterministic and documented;
- zero-topic records undergo the targeted eligibility re-screen before Workflow 08 flagging;
- included zero-topic records are explicitly retained as included but uncoded;
- consensus zero-topic exclusions are recorded as late exclusions without rewriting W04;
- unresolved zero-topic eligibility and extreme three-pass disagreement are explicitly routed to Workflow 08;
- final routing counts and identity invariants pass the finalisation validator; and
- expensive completed model outputs can be reused without rerunning classification.

These conditions are satisfied for the current baseline. The integrated final-routing implementation was validated against the preserved production topic handoff and zero-topic rescreen in GitHub Actions run **36305907080**. The validator confirmed 19,407 records, 358 zero-topic records, 217 included-but-uncoded records, 123 late automatic exclusions, 18 zero-topic eligibility-uncertain records, 103 extreme-disagreement records, and **121 total Workflow 07 human-adjudication records**.\n\n**Workflow 07 status: complete, validated and ready for Workflow 08 consumption.**

