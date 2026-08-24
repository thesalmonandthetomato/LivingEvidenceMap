# Full-text coding workflow

This directory contains the reproducible full-text annotation pathway for the LivingEvidenceMap corpus.

## Scope

Coding is deliberately lightweight and is intended for broad corpus annotation rather than full systematic-review data extraction.

The workflow extracts, where supported by the text:

- document type
- contribution type
- review type
- study design
- research approach
- setting
- sample size and unit
- study period
- study location and country
- species
- population/production setting
- outcome measured
- intervention
- comparator
- a consistently phrased research question
- a 1–2 sentence objectives summary
- ontology assignments using `data/reference/topic_ontology_v3.csv`
- evidence passages supporting substantive coding decisions

## Evidence priority

The model must prioritise evidence in this order:

1. Methods
2. Results
3. Only where the research focus remains unclear, the final two paragraphs of the Introduction/Objectives

The general Introduction/background is not used to infer substantive ontology assignments merely because topics are mentioned there.

## Reproducibility

The schema and prompt are versioned separately from the downloaded corpus. Every annotation record should contain:

- `schema_version`
- `ontology_version`
- model/provider metadata
- run timestamp
- source identifier
- evidence passages used for substantive coding

The canonical ontology remains the repository CSV. It is not duplicated into the output records except through the selected `path_id`, hierarchy path, and evidence.

## Output design

JSON is the per-document interchange format. A downstream R process can combine these records into a tabular master object (CSV/Parquet) and use the structured fields for interactive databases and visualisations.

The output is intentionally flat at the top level for analysis, with a nested `evidence` object for provenance.

## Test-first use

Run the workflow against a small, explicitly selected set of already downloaded/cached full texts before scaling to the complete corpus. Do not run the full corpus until the test outputs have been reviewed.
