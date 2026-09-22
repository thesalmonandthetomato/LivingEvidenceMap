# Pipeline stage renaming plan

This document records the intended stage order after the current deduplication work is validated. It is a planning document only and does not rename live workflows yet.

## Intended production order

1. **Workflow 00 — Search / ingestion**
2. **Workflow 01 — Deduplication / reconciliation**
3. **Workflow 02 — Repair / enrichment**
4. Downstream relevance screening, annotation and topic-coding stages

## Rationale for the swap

The current repository numbering places enrichment before deduplication. That is inefficient and can make DOI-derived metadata act as a proxy for the DOI already used in duplicate identification.

The intended production sequence is therefore:

`Workflow 00 search -> Workflow 01 deduplication -> Workflow 02 repair/enrichment`

The current live deduplication run must finish before any renaming is performed.

## Current-to-future mapping

| Current stage | Future stage | Action |
|---|---|---|
| Workflow 00 search / ingestion | Workflow 00 search / ingestion | keep |
| Workflow 02 deduplication / multisource reconciliation | Workflow 01 deduplication / reconciliation | rename after validation |
| Workflow 01 enrichment / abstract repair | Workflow 02 repair / enrichment | replace/refactor after deduplication validation |

## Renaming constraints

- Do not rename files or workflows while run **35711465359** is active.
- Preserve all current deduplication artefacts and pair classifications before renaming.
- Rename only after the complete deduplication corpus, including later WoS records where necessary, has been reconciled and validated.
- Update workflow names, YAML filenames, R script names, documentation references and downstream dependencies together.
- Do not alter `main` until the complete candidate pipeline has passed end-to-end.
