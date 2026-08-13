# Salmon Scoping Review — migration status

This document tracks the migration from `nealhaddaway/salmonscopingreview` into this repository.

The scope is deliberately **salmon-specific**. The aim is to maintain a robust living evidence map for the salmon scoping review, not a generic evidence-map framework.

## Current state

### Ported and tested

- Target configuration and target/input validation
- Stable `record_id` integrity checks
- RIS/corpus parsing and cleaning needed for the Lens update
- Deduplication and publication-status handling
- Relevance-screening interfaces and established screening decisions/model resources
- Species mention detection/filtering/assignment
- Geography mention detection and primary study-country assignment
- LLM adjudication for defined uncertain species/geography cases
- Topic-stage integration sufficient for controlled API testing
- Automated tests for the above components
- CI running the complete `testthat` suite

### Present in the legacy project and being reproduced in the new repository

- Full salmon topic mention detection and topic hierarchy classification
- Full topic annotation runner and topic reference data where required
- End-to-end production update runner and final dataset construction
- Final incorporation of a validated update into the living master evidence map

The legacy repository is **not a runtime dependency**. Required inputs, models, dictionaries and update files are being moved into `LivingEvidenceMap` so that the production workflow is self-contained.

## Scientific workflow to preserve

1. Prepare/read the incoming Lens.org corpus.
2. Deduplicate against both the incoming corpus and the existing salmon evidence-map corpus.
3. Remove retractions and publication notices.
4. Screen for relevance using the established salmon screening workflow.
5. Annotate farmed salmon species.
6. Annotate geography.
7. Assign primary study country.
8. Adjudicate explicitly uncertain species/geography assignments **after annotation**.
9. Validate annotations.
10. Annotate topics using the established salmon topic hierarchy.
11. Construct the final evidence-map dataset.
12. For subsequent updates, process genuinely new records and incorporate a validated update with provenance.

## LLM/API policy for the current Lens refresh

The current Lens update is the same substantive update previously performed in the legacy workflow. We therefore do not regenerate already-established screening decisions unnecessarily.

Because screening, species/geography adjudication and topic annotation have API-dependent components, each is given a small controlled API integration test during the refresh. The full topic stage remains part of the production pipeline, but the current refresh uses only a small topic test rather than full-corpus topic reprocessing.

## Human-review direction

The validated LLM adjudication workflow is intended to reduce and ultimately eliminate routine human review. Any cases that remain genuinely unresolved must be represented as an explicit, auditable review state; they must not be silently forced into a final classification.

## Migration rule

The legacy repository is a provenance/reference source only. A migrated component should remain materially equivalent to the validated salmon workflow unless a deliberate scientific or engineering change is documented and protected by tests.
