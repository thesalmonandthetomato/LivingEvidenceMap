# Salmon scoping review pipeline

## Purpose

This document is the authoritative description of the processing sequence for the **salmon scoping review living evidence map**. It is specific to the salmon review and is not a generic evidence-map framework.

The repository is self-contained. The former `salmonscopingreview` repository is used only for historical implementation provenance and is not a runtime dependency.

## Required production sequence

1. **Lens.org RIS import and parsing** — read and clean the incoming Lens corpus using the established RIS handling rules.
2. **Deduplication** — identify duplicates within the incoming Lens corpus and identify records already represented in the existing salmon evidence-map corpus.
3. **Publication-status filtering** — remove retractions and publication notices using the established publication-status workflow and OpenAlex lookup logic.
4. **LLM relevance screening** — apply the established salmon relevance-screening workflow. Existing validated screening decisions and model resources are retained; routine regeneration of already-established decisions is avoided.
5. **Species annotation** — detect species mentions and assign farmed salmon species using the validated species dictionary and assignment rules.
6. **Geography annotation** — detect country and macro-region mentions using the validated gazetteer and longest-match/precedence rules.
7. **Primary study-country assignment** — derive candidate study countries from geography evidence and assign or queue according to the documented classifier.
8. **Species/geography LLM adjudication** — resolve explicitly defined uncertain species/geography cases **after** deterministic annotation has been generated. Adjudication is not a substitute for annotation.
9. **Validation** — check adjudicated annotations and structural invariants before dataset construction.
10. **Topic annotation** — annotate the validated target corpus according to the established salmon topic hierarchy. Topics remain a required production stage and are always last among the substantive annotation stages.
11. **Dataset construction** — assemble the final target dataset. Only after target-level validation should an update be incorporated into the master evidence map.

## Current Lens refresh

The current update is a reproduction of the established Lens update workflow in this repository. The update-specific inputs and outputs are stored under `data/updates/2026-08-13_lens/`.

The current refresh does **not** unnecessarily rerun expensive full-corpus LLM work where the established decisions/methods already provide the validated basis. Small API integration tests are nevertheless required for each LLM-dependent stage, including screening, species/geography adjudication, and topics. The topic stage therefore remains in the pipeline and is explicitly tested even though the full topic corpus is not reprocessed during this refresh.

## Deduplication versus screening reference data

The existing evidence-map corpus is the reference for determining whether an incoming record is already represented in the map. Screening include/exclude decisions are a separate resource used by the established relevance-screening workflow. They must not be treated as the deduplication corpus.

## LLM and human-review policy

LLM adjudication is downstream of deterministic annotation. Decisions and supporting evidence should remain auditable. The intended direction is to reduce and ultimately eliminate routine human review as the validated adjudication workflow becomes sufficiently reliable; any unresolved review queue must remain explicit rather than being silently converted to a final decision.

## Target isolation

Every stage must receive an explicit target configuration. A stage must fail if required target inputs are absent or if an input contains records outside the requested target without an explicit, documented reason.

## Porting policy

The legacy repository provides implementation provenance. Methods are ported selectively and should remain scientifically equivalent unless a deliberate change is documented and tested. No production stage should read from or otherwise depend on the legacy repository.
