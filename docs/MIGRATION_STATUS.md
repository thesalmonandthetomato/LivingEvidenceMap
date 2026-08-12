# Salmon Living Evidence Map — migration status

This document tracks the migration from `nealhaddaway/salmonscopingreview` into this repository.

The scope is deliberately **salmon-specific**. The aim is to build a robust living evidence map for salmon, not a generic evidence-map framework.

## Current state

### Ported and tested

- Target configuration and target/input validation
- Stable `record_id` integrity checks
- Species mention detection/filtering/assignment
- Geography mention detection
- Primary study-country assignment
- LLM adjudication for defined uncertain species/geography cases
- Automated tests for the above components
- CI running the complete `testthat` suite

### Present in the legacy project but not yet ported

- Corpus/RIS parsing and cleaning (`read_corpus.R`)
- Relevance screening and conservative deduplication (`relevance_screening.R`)
- Topic mention detection
- Topic hierarchy classification and the current single-call LLM classifier
- Topic annotation runner
- Topic ontology/dictionary and related reference data
- Any production runners/scripts needed to execute the complete sequence end-to-end
- Construction of the final salmon evidence-map dataset from all annotation stages
- Living-update workflow that takes a new corpus, screens/deduplicates it against the master, annotates new records, validates them, and incorporates the update
- Migration of the current production data/archive structure

## Legacy scientific workflow to preserve

1. Prepare/read the incoming corpus.
2. Screen for relevance and resolve duplicates.
3. Annotate farmed salmon species.
4. Annotate geography.
5. Assign primary study country.
6. Adjudicate explicitly uncertain species/geography cases.
7. Validate annotations.
8. Annotate topics using the established salmon topic hierarchy.
9. Construct the final evidence-map dataset.
10. For subsequent updates, compare the new corpus against the master, process genuinely new records, and update the master with provenance.

## Immediate next build step

Port the **relevance screening and deduplication stage** from the legacy repository into a clean, tested implementation in `LivingEvidenceMap`.

This is the next missing stage in the documented pipeline and should be completed before topic annotation, because topic annotation is intended to operate on the validated/relevant target corpus.

The port should preserve the existing scientific behaviour while removing legacy assumptions about working directories and implicit filenames. It should not redesign the salmon screening methodology unless a specific problem is identified and documented.

## Migration rule

The legacy repository remains the scientific implementation reference. A port should be materially equivalent unless the new repository explicitly documents a deliberate change, with tests added for the behaviour that matters scientifically.
