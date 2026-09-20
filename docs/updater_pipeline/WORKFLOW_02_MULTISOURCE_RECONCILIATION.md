# Workflow 02: multi-source reconciliation

## Status

Development implementation on branch `workflow02-multisource-reconciliation`.

This workflow replaces the Lens-only/pairwise Workflow 02 implementation for the multi-source evidence map. It is implemented in R.

## Inputs

Workflow 02 consumes the four Workflow 01 outputs:

- Lens
- Scopus
- OpenAlex
- AGRICOLA

It also checks out the current canonical JSON at run time from an explicitly supplied `canonical_ref` (default `canonical-repair-store`). The canonical checkout is read-only and its exact commit SHA is recorded in the Workflow 02 report.

## Canonical overlay and preservation contract

The current canonical JSON may continue to evolve in parallel with this branch.

For every Workflow 01 Lens record whose Lens ID is present in the selected canonical JSON, Workflow 02 starts from the entire current canonical record. This is deliberate: existing non-bibliographic state must not be lost merely because the record is being re-reconciled against new bibliographic sources.

The overlay therefore preserves, without rewriting:

- screening state;
- species annotations;
- geography annotations;
- topic assignments/codes;
- publication-status information;
- retractions, notices and expressions of concern;
- prior deduplication information;
- provenance and other existing top-level metadata.

Workflow 01 abstract enrichment is allowed to update only `canonical.abstract` when Workflow 01 explicitly records that Europe PMC enriched or repaired the abstract. The Workflow 01 `abstract_enrichment` provenance object is also carried forward.

The old `deduplication` object is never overwritten by this workflow. New multi-source identity decisions are written separately under `reconciliation`.

## Re-annotation policy

Existing annotations are reused.

Workflow 02 produces explicit queues for representative records that lack:

- species and/or geography annotation;
- topic coding;
- publication-status/retraction checking.

No model or external API is called by Workflow 02 itself.

Downstream annotation workflows should consume only these missing-annotation queues rather than reprocessing records that already have valid annotations.

## Candidate generation

The workflow does not perform all-pairs comparison.

Candidates are generated through multiple blocking routes:

1. exact normalised DOI;
2. exact normalised title;
3. first-author surname + publication year;
4. journal + volume + pages/article number;
5. previously human-reviewed duplicate Lens-ID pairs.

Large pathological blocks are capped and reported rather than expanded combinatorially.

## DOI handling

DOI is strong evidence but never decisive in isolation.

- same DOI + compatible title and supporting bibliographic evidence may be automatically reconciled;
- same DOI + incompatible title is an explicit `doi_conflict`;
- different DOI does not establish non-duplication;
- strong bibliographic agreement with different DOI is retained for review.

## Human adjudication

The current reviewed duplicate and not-duplicate artefacts are loaded before clustering.

Human-reviewed decisions override automatic rules.

Where a reviewed duplicate specifies a preferred canonical Lens ID, that record receives highest representative-selection priority.

## Clustering

Accepted deterministic duplicate edges are converted into work clusters using union-find.

Each source manifestation remains present in `multisource_manifestations.jsonl`. No source record is destructively deleted.

Each cluster has one representative record for downstream processing.

Representative priority is:

1. human-preferred canonical Lens manifestation, where specified;
2. current canonical-overlay Lens record;
3. Lens record;
4. record with abstract;
5. non-preprint/non-conference manifestation.

Clusters containing contradictory evidence, including same-DOI title conflicts or implausible publication-year spans, are marked `review_required` and are not considered resolved for downstream promotion.

## Outputs

- `multisource_manifestations.jsonl`: all source manifestations with reconciliation provenance;
- `representative_records.jsonl`: one representative per cluster;
- `candidate_pairs.jsonl`: all generated candidate pairs and their evidence/classification;
- `clusters.jsonl`: cluster membership and representative choice;
- `annotation_inventory.jsonl`: annotation-presence audit on representatives;
- `needs_species_geography_annotation.jsonl`;
- `needs_topic_coding.jsonl`;
- `needs_publication_status_check.jsonl`;
- `report.json`.

## Parallel-development rule

This branch does not write to `canonical-repair-store`.

A run explicitly records:

- Workflow 02 code commit;
- Workflow 01 source run ID;
- canonical ref;
- canonical commit SHA.

A later promotion step can therefore be performed deliberately after the Lens canonical pipeline and multi-source reconciliation pipeline are both complete and validated.

## Canonical schema v2 design gate

Do not finalise the multi-source canonical bibliographic schema until the Web of Science (WoS) field inventory is available.

Before schema finalisation, perform a cross-source field inventory covering at least:

- Lens;
- Scopus;
- OpenAlex;
- AGRICOLA;
- Web of Science.

Semantically equivalent fields must be mapped across providers before deciding which attributes belong in canonical core metadata, canonical extended metadata, source-specific metadata, or technical provenance only. The canonical datatype must be defined independently of any one provider and should not be frozen piecemeal before the WoS inventory has been assessed.
