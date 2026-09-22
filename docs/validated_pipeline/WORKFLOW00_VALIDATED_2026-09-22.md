# Validated Workflow 00 snapshot — 2026-09-22

This file records the validated five-source search/update layer and the exact recovery points used to reproduce it.

## Status

Workflow 00 is validated for all three supported modes:

- full search
- fortnightly update
- ad hoc expansion

Validated sources:

- Lens
- Scopus
- OpenAlex
- AGRICOLA
- Web of Science Core Collection / Starter API path

Key validation runs:

- five-source fortnightly integration: GitHub Actions run **35764618096** — PASS
- OpenAlex fortnightly current-year + next-year optimisation: GitHub Actions run **35769376886** — PASS
- all-five-source expansion integration: GitHub Actions run **35774020363** — PASS

The complete Workflow 00 validation head used by the final expansion integration run was:

`a9dbf4df826c6b3552a066377049c03afc525861` on `workflow00-search-orchestrator`.

## Source implementation recovery points

| Component | Working source at validation | Exact validated implementation commit | Frozen branch |
|---|---|---|---|
| Lens | `main` | `d2a9a84243d19b29165543f10f1a4f5907eded19` | `validated-workflow00-lens-2026-09-22` |
| Scopus | `updater-workflow-00b-scopus-ingestion` | `95dc114d036e699e2b34293fc893c315e318537a` | `validated-workflow00-scopus-2026-09-22` |
| OpenAlex | `updater-workflow-00c-openalex-ingestion` | `3a6367b40859f1784fc7dd22286988cb329e8c05` | `validated-workflow00-openalex-2026-09-22` |
| AGRICOLA | `updater-workflow-00d-agricola-ingestion` | `b4854bc3c52bfc48d3596bb35057ffe4b86737fa` | `validated-workflow00-agricola-2026-09-22` |
| WoS | `updater-workflow-00e-wos-starter-ingestion` | `eddc6e929e0f776937e56dfd40d9bdfbb72786ea` | `validated-workflow00-wos-2026-09-22` |

Earlier frozen orchestrator recovery branch: `validated-workflow00-orchestrator-2026-09-22`.

Important: the earlier frozen orchestrator branch predates the final all-source expansion integration validation. For complete Workflow 00 reconstruction, use the final validation head `a9dbf4df826c6b3552a066377049c03afc525861` plus the source implementation commits above. Do not assume the earlier frozen orchestrator branch alone represents the final validated state.

## Validated behaviour

- Full harvests were completed across all five sources. Failed source jobs in earlier combined full-search attempts were recovered successfully.
- Fortnightly Lens, Scopus, AGRICOLA and WoS source-specific incremental logic is retained.
- OpenAlex fortnightly searching is restricted to the current and following publication year; full and expansion searches remain unrestricted.
- OpenAlex raw API pages remain unmodified.
- Exact repeated OpenAlex Work IDs caused by live-index cursor drift are recorded and deterministically collapsed before identifier-delta comparison.
- AGRICOLA zero-result fortnightly harvests are valid and do not fail sidecar adaptation.
- Ad hoc expansion runs add one additional farm/aquaculture synonym while keeping species terms immutable.
- Expansion reconciliation uses exact native source identifiers before downstream bibliographic deduplication.
- Search records, source harvest artefacts, expansion reconciliation artefacts and consolidated search archives passed.

## Production promotion rule

Do not reconstruct Workflow 00 from memory and do not selectively copy files from old branches.

When the entire pipeline is validated:

1. Start from the final validated Workflow 00 head recorded above.
2. Verify the source implementation branches against the exact implementation commits above.
3. Review any changes made after validation.
4. Consolidate the required source implementations and shared orchestration into the production branch.
5. Run the complete pipeline from search through final outputs on the candidate production branch.
6. Only after that complete run passes, merge/promote to `main`.
7. Remove obsolete standalone search workflows only after the production pipeline is verified on `main`.
8. Keep recovery branches until the production merge and a subsequent scheduled run have both passed.

## Scope

This snapshot certifies **Workflow 00 search/update behaviour only**. It does not certify downstream stages unless a later validated-pipeline manifest explicitly says so.
