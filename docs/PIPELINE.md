# Pipeline specification

## Purpose

This document is the authoritative description of the processing sequence. It is intentionally separate from individual script filenames so implementation can change without changing the scientific workflow.

## Required sequence

1. **Prepare target corpus** — establish the exact records that constitute the target and validate the record schema.
2. **Screen and deduplicate** — apply deterministic screening/duplicate logic, then adjudicate unresolved screening cases as required.
3. **Species annotation** — detect species mentions and assign farmed species using the validated species dictionary and assignment rules.
4. **Geography annotation** — detect country and macro-region mentions using the validated gazetteer and longest-match/precedence rules.
5. **Primary study-country assignment** — derive candidate study countries from geography evidence and assign or queue for review according to the documented classifier.
6. **LLM adjudication** — resolve explicitly defined uncertain species/geography cases. This is downstream of deterministic annotation, not a replacement for it.
7. **Validation** — check adjudicated annotations and structural invariants before dataset construction.
8. **Topic annotation** — annotate the validated target corpus according to the topic specification.
9. **Dataset construction** — assemble the final target dataset. Only after target-level validation should an update be incorporated into a master dataset.

## Target isolation

Every stage must receive an explicit target configuration. A stage must fail if required target inputs are absent or if an input contains records outside the requested target without an explicit, documented reason.

## Porting policy

The legacy `salmonscopingreview` repository is the source of implementation provenance. Code is ported selectively rather than copied wholesale. Each ported component should be simplified, tested, documented, and given one authoritative filename in this repository.
