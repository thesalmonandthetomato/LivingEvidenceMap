# Workflow XX: [workflow title]

## Purpose

Briefly state what this workflow does, why it exists in the pipeline, and what methodological function it serves.

This document is intended to serve two purposes:

1. as a methodological guide to the repository implementation; and
2. as source text for reporting the workflow in a research paper.

## Functionality map

Provide a compact ASCII flow showing:

- principal inputs;
- orchestration or processing stages;
- important branch points;
- outputs;
- handoff to the next workflow.

```text
[input]
   |
   v
[workflow/controller]
   |
   |-- [stage]
   |-- [stage]
   '-- [output]
          |
          v
[next workflow]
```

## Components

| Component | Function |
|---|---|
| `path/to/component` | Concise description of its role. |

## Inputs and methodological rules

Describe the authoritative inputs, configuration files, schemas, ontologies, prompts, thresholds or decision rules. Distinguish permanent methodological definitions from run-specific generated inputs.

## Processing modes or stages

Use short subsections where the workflow has distinct modes, stages or branches.

### [Mode/stage]

State what happens and under what conditions.

## Provenance and documentation

List the information recorded for each run or record. Include identifiers, dates, source information, model or rule versions, counts, checksums and other reproducibility metadata as relevant.

## Storage and archival model

### Permanent repository records

List lightweight files retained in GitHub as part of the durable methodological record.

### Short-lived GitHub Actions artefacts

List operational artefacts and retention period.

### Durable external archive

Describe any Zenodo or other durable storage, including what is deposited and how it is referenced from the repository.

## Downstream handoff

State exactly what output becomes the input to the next workflow and how integrity/provenance are verified.

## Methods text for research reporting

> **Workflow XX: [short methods heading].** Write a concise, publication-ready paragraph describing the workflow in methodological terms without implementation detail that would be inappropriate for a paper.

## Reporting status

Define the conditions under which the workflow can be considered complete and validated.
