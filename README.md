# LivingEvidenceMap

A reproducible R pipeline for maintaining a living evidence map.

## Design principles

- Every pipeline run operates on an explicit **target** (for example, `MASTER` or a dated update).
- Inputs and outputs are target-specific; scripts do not hard-code corpus filenames or output directories.
- Each processing stage has one authoritative implementation.
- Intermediate data are treated as explicit stage outputs rather than implicit working state.
- Scientific decisions and validation rules are documented alongside the code.
- External/LLM adjudication is isolated from deterministic annotation.
- Dependencies are kept deliberately small and managed with `renv`.
- Tests protect the parts of the pipeline where small implementation changes can alter scientific results.

## Pipeline

The intended high-level sequence is:

1. Prepare the target corpus.
2. Screen records for relevance and resolve duplicates.
3. Annotate farmed species.
4. Annotate geography.
5. Assign primary study country where applicable.
6. Adjudicate uncertain species/geography assignments.
7. Validate annotations.
8. Annotate topics.
9. Build the final target dataset and, where appropriate, update the master dataset.

The exact implementation and dependencies are documented in `docs/PIPELINE.md` as the pipeline is ported from the legacy repository.

## Repository structure

```text
config/       Target and project configuration
R/            Reusable functions
scripts/      Executable pipeline stages
data/         Reference data and dictionaries (not working outputs)
outputs/      Target-specific generated outputs
tests/        Automated tests and small fixtures
docs/         Pipeline, methods and data documentation
```

## Targets

Targets are explicit configuration objects. A target defines the corpus and reference inputs to be used by a run and the corresponding output namespace. Scripts must receive or resolve a target explicitly; they must never infer the target from whatever files happen to exist in an output directory.

## Provenance

This repository is a clean reimplementation of the validated scientific workflow developed in the previous `salmonscopingreview` repository. Legacy code will be ported selectively, with provenance documented where the implementation has been retained or materially changed.

The legacy repository is treated as a reference/archive, not as a runtime dependency.

## Status

**Architecture phase.** The repository has been initialized. Scientific pipeline code is being ported and tested incrementally before the next living-map update is run.
