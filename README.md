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

## Current Lens update

The current update is stored under `data/updates/2026-08-13_lens/`. It reproduces the established Lens update workflow in this repository rather than depending on files in the legacy repository.

For this refresh, the full topic methods remain part of the pipeline. Because the topic API is comparatively expensive, only a small topic API integration test is run during the refresh rather than reprocessing the full corpus. The same principle is applied to the established LLM screening and adjudication interfaces: small API checks are used to verify integration, while existing validated decisions and methods are preserved rather than unnecessarily regenerated.

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
docs/         Pipeline, methods, migration and data documentation
```

## Deduplication

Deduplication has two distinct purposes:

- identify duplicates within the incoming Lens corpus; and
- identify incoming records that are already represented in the existing salmon evidence-map corpus.

The screening include/exclude decisions are **not** the deduplication reference corpus. They are maintained as part of the established screening workflow and its provenance.

## LLM use and human review

LLM components are used only where they form part of the established scientific workflow. Deterministic annotation remains separate from LLM adjudication.

The long-term aim is to minimise or eliminate routine human review by improving the validated LLM adjudication workflow. Any residual review queue must be explicit and auditable rather than silently resolved.

## Validation

The repository has an automated `testthat` suite covering the critical parsing, deduplication, screening, species, geography, adjudication and target-I/O components. CI is expected to pass before a production update is treated as complete.

## Provenance

This repository is the maintained implementation of the salmon scoping-review evidence-map workflow. The legacy `salmonscopingreview` repository provides historical implementation provenance only. Ported methods should remain scientifically equivalent unless a deliberate change is documented and tested.
