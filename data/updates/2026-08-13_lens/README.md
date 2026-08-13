# Lens.org update — 2026-08-13

This directory contains the complete input and outputs for the Lens.org refresh dated 2026-08-13.

## Pipeline order

1. Lens RIS import
2. Bramer-style deduplication against the current evidence-map corpus and within the new import
3. Retraction and publication-notice removal
4. Statistical relevance screening
5. LLM adjudication of statistically uncertain screening decisions
6. Species annotation
7. Geography annotation
8. Species/geography LLM adjudication
9. Topics remain the final implemented stage, but are not rerun for this refresh

## Important distinction

The relevance-model training examples (historical included/excluded records) are separate from deduplication. Deduplication compares incoming records with the current evidence-map corpus and with one another; it does not use the screening training set as a substitute for the existing corpus.
