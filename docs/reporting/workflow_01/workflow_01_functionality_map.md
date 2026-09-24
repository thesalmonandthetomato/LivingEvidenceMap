# Workflow 01: Multi-source deduplication, adjudication and canonicalisation

## Purpose

Workflow 01 reconciles bibliographic records retrieved by Workflow 00 into source-agnostic scholarly works. It preserves the provenance of every Lens, Scopus, OpenAlex, AGRICOLA and Web of Science manifestation, applies deterministic and model-assisted duplicate decisions, incorporates integrity-gated human adjudication, strips demonstrably misattached abstracts, and writes the canonical JSONL corpus used by the remaining pipeline.

This document is intended to serve two purposes:

1. as a methodological guide to the repository implementation; and
2. as source text for reporting the workflow in a research paper.

## Functionality map

```text
Workflow 00 restricted Zenodo harvests
          |
          v
restore + verify source inputs
          |
          v
normalise five-source manifestations
          |
          |-- preserve historical pair decisions
          |-- generate candidates involving new manifestations
          |-- deterministic duplicate classifier
          '-- unresolved / ambiguous candidate pairs
                         |
                         v
                 LLM adjudication
                         |
             +-----------+-----------+
             |                       |
       high-confidence            human review
       final decision             integrity gate
             |                       |
             +-----------+-----------+
                         |
                         v
                  final pair state
                         |
                         v
             reconstruct work clusters
                         |
             |------------------------|
             |                        |
   abstract/title mismatch       canonical materialisation
       strip action                    |
             |                         v
             |                canonical records.jsonl
             |                         |
             '----> stripped manifestation metadata
                                       |
                                       v
                                  Workflow 03
                         missing-title/abstract repair scan
```

## Components

| Component | Function |
|---|---|
| `scripts/updater/workflow_01_deduplication_build_union.R` | Constructs the provenance-safe five-source manifestation union while preserving historical manifestation indexing. |
| `scripts/updater/workflow_01_deduplication_incremental_candidates.R` | Normalises bibliographic metadata and generates candidate duplicate pairs, scoring only pairs involving newly added manifestations. |
| `scripts/updater/workflow_02_deduplication_v2_identifier_rescore.R` | Applies the frozen deterministic duplicate classifier used by Workflow 01. |
| `scripts/updater/workflow_01_llm_adjudicate_duplicates.R` | Adjudicates residual ambiguous pairs using the configured model and conservative automatic-promotion rules. |
| `scripts/updater/workflow_01_render_human_review_batch.R` | Mechanically renders locked human-review batches from the immutable queue. |
| `scripts/updater/workflow_01_validate_human_review_batch.R` | Enforces exact case membership and immutable pair/source identities for submitted human decisions. |
| `scripts/updater/workflow_01_validate_human_review_state.R` | Applies the final integrity barrier to the complete human-review state. |
| `scripts/updater/workflow_01_apply_adjudications_and_recluster.R` | Applies final LLM/human decisions, reconstructs work clusters and emits abstract-strip actions. |
| `scripts/updater/workflow_01_build_canonical_jsonl.R` | Materialises one source-agnostic canonical JSONL record per final work cluster while retaining its source manifestations. |
| `scripts/updater/workflow_01_archive_state_to_zenodo.R` | Deposits the durable Workflow 01 final state and canonical corpus to restricted Zenodo storage. |

## Inputs and methodological rules

Workflow 01 consumes the exact Workflow 00 search outputs registered in the repository and archived on restricted Zenodo. Source archives are restored using stored byte sizes and SHA-256 checksums.

Each bibliographic manifestation is identified by the immutable combination of source namespace and native source record identifier. Historical manifestation indices and previously resolved pair decisions are preserved; new searches therefore extend rather than silently recreate prior deduplication state.

Candidate discovery uses exact identifiers and bibliographic blocking together with fuzzy-title candidate discovery. Automatic duplicate rules are conservative. Pairs that contain material conflicts or insufficient metadata are routed to adjudication rather than being merged solely because they share a title, DOI family, abstract or study context.

The LLM adjudicator distinguishes manifestations of the same publication from separate outputs of the same underlying study. Automatic promotion requires the configured confidence threshold. For exact-abstract cases, title/abstract consistency is explicitly checked. Detected abstract/title mismatches and not-duplicate decisions involving missing titles are routed conservatively rather than automatically resolved.

Human adjudication is bound to a locked queue by SHA-256. Decisions must exactly match the expected review-case IDs, and all data-quality repairs must target an immutable source record belonging to the reviewed pair.

## Processing stages

### Five-source union and candidate generation

Records from Lens, Scopus, OpenAlex, AGRICOLA and Web of Science are normalised into a common comparison representation. Prior-corpus source IDs retain their historical row positions. Only newly introduced manifestations generate new candidate comparisons against the preserved pair-decision state.

### Deterministic classification

Candidate pairs are evaluated using identifier, title, author, year, journal, pagination and abstract evidence. Previously calibrated rules produce automatic duplicate/non-duplicate decisions or route residual cases for adjudication.

### Model-assisted adjudication

Residual cases are passed to the configured LLM using a publication-identity prompt. High-confidence cases may be automatically resolved. Ambiguous cases are retained for human review.

A blinded random validation sample of 40 cases was used to evaluate automatic decisions. A subsequent 20-case targeted audit assessed the exact-abstract risk stratum. The exact-abstract safety guard was then retrospectively evaluated on 34 human-labelled cases using a zero-wrong-automatic-decision criterion.

### Human review

Human-review cases are mechanically rendered from the locked queue rather than reconstructed from conversation or prose. Submitted decisions are checked for complete exact-set equality against the locked queue before they can affect clustering.

### Abstract mismatch handling

If adjudication identifies an abstract that is semantically inconsistent with its own record title, Workflow 01 records an immutable strip action and removes the abstract during canonical materialisation. It does not repair the abstract and does not rerun deduplication. Workflow 03 subsequently discovers the resulting missing abstract through its normal corpus scan and performs any DOI-based or other verified enrichment.

### Canonical JSONL materialisation

The final output is one source-agnostic JSON object per deduplicated work. Stable identifiers are generated as `work-<16-character SHA-256-derived ID>` values from sorted source manifestation identities.

Each canonical object retains:

- the stable work identity;
- a canonical bibliographic representation;
- all source manifestations and their source-native identifiers;
- field-level provenance for canonical bibliographic values;
- Workflow 01 provenance and deduplication status;
- Workflow 03 abstract-enrichment status;
- placeholders for downstream screening, species, geography and topic annotations.

Canonical field selection is deterministic and source-agnostic. Non-empty values are compared across manifestations; the most-supported normalised value is selected, with deterministic tie-breaking. Source manifestations remain available so no source provenance is lost.

## Provenance and documentation

Workflow 01 records, where applicable:

- Workflow 00 source archive identifiers and checksums;
- source namespace and source-native record identifier;
- candidate-generation and pair-decision provenance;
- deterministic rule or LLM decision source;
- model name, confidence and rationale;
- human review-case identifiers and decisions;
- locked queue SHA-256;
- abstract-strip actions and original stripped values;
- final cluster identifiers and member manifestations;
- canonical JSONL record counts, byte size and SHA-256;
- GitHub Actions run identifiers;
- Zenodo record identifier, DOI and archive checksums.

Each final run writes a machine-readable JSON run report and a human-readable Markdown run report under `docs/deduplication/runs/`.

## Storage and archival model

### Permanent repository records

GitHub stores only lightweight methodological and provenance material:

- Workflow 01 implementation and validation code;
- this functionality/methods report;
- per-run Markdown and JSON reports;
- human decision and audit metadata;
- `docs/deduplication/zenodo_registry.csv`;
- one small Zenodo JSON pointer per archived Workflow 01 run.

The canonical bibliographic corpus is not stored through Git LFS.

### Short-lived GitHub Actions artefacts

Operational intermediate files may be retained temporarily to support workflow recovery and validation. They are not treated as the durable corpus archive.

### Durable external archive

Each completed final Workflow 01 run is archived as a restricted Zenodo record. The final archive includes the canonical JSONL, its manifest, final pair/cluster state, adjudication audit and other files required to reproduce the final deduplication output.

The repository stores the Zenodo DOI, record identifier, archive checksums and canonical JSONL checksum. Downstream workflows restore the canonical corpus from Zenodo and verify it before use.

## Downstream handoff

The authoritative Workflow 01 handoff is the checksum-verified canonical JSONL stored in the final restricted Zenodo archive.

Workflow 03 restores this file from the registered Zenodo record. It scans the canonical manifestations for missing titles and abstracts, including abstracts stripped by Workflow 01 because of detected metadata contamination. All later screening, species, geography and topic stages operate on the same canonical work records rather than reconstructing deduplication.

## Methods text for research reporting

> **Workflow 01: bibliographic deduplication and canonicalisation.** Search results from Lens, Scopus, OpenAlex, AGRICOLA and Web of Science were reconciled using an R-based deduplication workflow that preserved source-native record identities and previously resolved pair decisions. Candidate duplicates were identified using bibliographic identifiers, titles, authorship, publication metadata and abstract similarity. Deterministic rules resolved well-supported cases, while residual ambiguous pairs were adjudicated using a language model with a predefined publication-identity prompt and conservative confidence threshold; unresolved cases were subjected to integrity-gated human review. Human-review queues were cryptographically locked to prevent case substitution or reconstruction errors. Potential metadata contamination identified during adjudication, including title-abstract mismatches, was stripped and documented for subsequent repair rather than used as evidence for merging. Final duplicate decisions were used to reconstruct source-agnostic work clusters, each retaining its constituent database manifestations and provenance. The resulting canonical JSONL corpus was checksum-verified and deposited as a restricted Zenodo record for downstream processing.

## Reporting status

Workflow 01 is considered complete when:

- all five source inputs have been restored and checksum-verified;
- all candidate pair decisions are final;
- the human-review integrity gate passes;
- no unresolved pair decisions remain;
- final clusters are reconstructed;
- abstract-strip actions are applied during canonical materialisation;
- the canonical JSONL and manifest pass structural and cardinality checks;
- the final state and canonical JSONL are deposited on restricted Zenodo;
- the Zenodo DOI, record identifier and checksums are registered in the repository; and
- the per-run Markdown and JSON reports are written to `docs/deduplication/runs/`.
