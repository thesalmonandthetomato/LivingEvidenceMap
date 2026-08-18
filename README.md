# Salmon Scoping Review — Living Evidence Map

A reproducible R pipeline for maintaining the **living evidence map for the salmon scoping review**. This repository is salmon-specific; it is not a generic living-evidence-map framework.

## Purpose

The repository contains the validated methods, reference data, models, tests, and update workflow used to maintain the salmon evidence map as new literature becomes available.

The repository is intended to be **self-contained**. The former `salmonscopingreview` repository is retained only as implementation/provenance history and is **not a runtime dependency** of this pipeline.

## Pipeline

The production workflow is:

1. Import and clean the incoming Lens.org RIS corpus.
2. Deduplicate the incoming records and compare them with the existing salmon evidence-map corpus.
3. Remove retractions and publication notices.
4. Screen records for relevance using the established salmon screening workflow.
5. Annotate farmed salmon species.
6. Annotate geography.
7. Assign the primary study country where applicable.
8. Adjudicate explicitly uncertain species/geography annotations.
9. Validate the resulting annotations and structural invariants.
10. Annotate topics using the established salmon topic hierarchy.
11. Construct the final update dataset and, after validation, incorporate it into the living evidence map.

**Ordering matters:** relevance screening precedes species/geography annotation; species/geography adjudication occurs only after those annotations have been generated; topics are the final substantive annotation stage.

## Annotation methods

Species and geography annotation are initially deterministic. Species annotation uses a curated salmonid species dictionary and predefined assignment rules to identify and normalise taxonomic mentions and distinguish eligible farmed salmonids from non-target or incidental mentions. Geographic annotation uses a curated gazetteer and matching/precedence rules to identify geographic entities and standardise country and regional information. Primary study country is assigned from the available geographic evidence using a documented evidence hierarchy. These deterministic stages are deliberately separated from subsequent LLM adjudication.

Records generating explicitly defined uncertainty flags are passed to an LLM adjudication stage. The model is supplied with the record title and abstract together with the deterministic annotation and supporting evidence, and is instructed to adjudicate only the flagged dimension. Adjudication uses constrained structured output and predefined decisions (ACCEPT, CHANGE, or UNRESOLVED), with a rationale recorded for each decision. Technical/API failures are recorded separately from substantive uncertainty. Records remaining unresolved are retained in an explicit human-review queue rather than silently assigned.

Research topics are assigned using a predefined three-level salmon topic ontology. The classifier evaluates the title and abstract against the permitted ontology paths and can assign multiple topics where each represents a substantive study objective, exposure, outcome, interpretation, or application. Isolated mentions or background context are not sufficient for assignment. Topic classification uses **GPT-5 mini**, accessed through the **OpenAI Responses API**, with structured output constrained to the predefined ontology. Model failures and review flags are retained separately from validated assignments.

Further methodological detail, including AI provenance and human validation, is provided in [`docs/METHODS.md`](docs/METHODS.md) and [`docs/AI_PROVENANCE.md`](docs/AI_PROVENANCE.md).

## LLM use and human validation

LLMs are used as components of a controlled scientific workflow rather than as unrestricted annotators. Deterministic rules establish the initial species and geographic annotations, while LLMs are used for relevance screening and for adjudication of explicitly flagged annotation uncertainty, and for ontology-constrained topic classification. Human validation provides an independent quality-control layer: unresolved or explicitly flagged cases are reviewed manually, review decisions are retained as auditable outputs, and a candidate update is not promoted when required review items remain unresolved. This combination of deterministic annotation, constrained LLM processing, automated validation, and human review is intended to improve reproducibility while limiting unsupported model inference.

## Current Lens update

The current update is stored under `data/updates/2026-08-13_lens/`. It reproduces the established Lens update workflow in this repository rather than depending on files in the legacy repository.

For this refresh, established validated decisions and methods are preserved where full-corpus regeneration is unnecessary. LLM-dependent stages retain small API integration/smoke tests to verify that the configured interfaces remain operational. Update-specific inputs, outputs, review queues and validation artefacts are retained for provenance.

## Weekly updating

The map is designed for weekly incremental updating. Each scheduled update retrieves the new Lens increment with a seven-day overlap to reduce the risk of records being missed because of indexing or retrieval delays. New records pass through the same deduplication, relevance-screening, species, geography, adjudication, human-review, validation and topic-classification stages. Automated validation is performed before promotion. Where unresolved screening, annotation, topic or technical review items remain, the candidate update is held until the relevant exceptions have been resolved. Validated updates are then incorporated into the master dataset and update-specific provenance and audit outputs are archived.

## Repository structure

```text
config/       Salmon-specific configuration and reference resources
models/       Validated screening/model objects
R/            Reusable functions
scripts/      Executable pipeline stages
data/
  reference/  Existing evidence-map corpus and stable reference data
  updates/    Dated incoming corpora and update-specific inputs/outputs
outputs/      Generated target outputs
tests/        Automated tests and small fixtures
docs/         Pipeline, methods, AI provenance, migration and data documentation
```

## Deduplication

Deduplication has two distinct purposes:

- identify duplicates within the incoming Lens corpus; and
- identify incoming records that are already represented in the existing salmon evidence-map corpus.

The screening include/exclude decisions are **not** the deduplication reference corpus. They are maintained as part of the established screening workflow and its provenance.

## Validation

The repository has an automated `testthat` suite covering the critical parsing, deduplication, screening, species, geography, adjudication and target-I/O components. CI is expected to pass before a production update is treated as complete.

## Provenance

This repository is the maintained implementation of the salmon scoping-review evidence-map workflow. The legacy `salmonscopingreview` repository provides historical implementation provenance only. Ported methods should remain scientifically equivalent unless a deliberate change is documented and tested. Update-specific inputs, decisions, review outputs and generated datasets should be retained sufficiently to reconstruct the provenance of each promoted master version.
