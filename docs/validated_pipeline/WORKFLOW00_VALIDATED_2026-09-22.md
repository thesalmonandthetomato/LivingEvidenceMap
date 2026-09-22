# Validated Workflow 00 snapshot — 2026-09-22

This file records the exact repository state used for the validated five-source search/update layer.

## Status

Validated for the fortnightly search architecture covering:

- Lens
- Scopus
- OpenAlex
- AGRICOLA
- Web of Science Core Collection / Starter API path

Full five-source integration validation: GitHub Actions run **35764618096** — PASS after rerun of failed jobs.

OpenAlex fortnightly current-year + next-year validation: GitHub Actions run **35769376886** — PASS.

## Frozen recovery branches

| Component | Working source at validation | Exact validated commit | Frozen branch |
|---|---|---|---|
| Orchestrator / shared Workflow 00 logic | `workflow00-search-orchestrator` | `be9b4a6b2a606eba663a801359b4f002a1f86a37` | `validated-workflow00-orchestrator-2026-09-22` |
| Lens | `main` | `d2a9a84243d19b29165543f10f1a4f5907eded19` | `validated-workflow00-lens-2026-09-22` |
| Scopus | `updater-workflow-00b-scopus-ingestion` | `95dc114d036e699e2b34293fc893c315e318537a` | `validated-workflow00-scopus-2026-09-22` |
| OpenAlex | `updater-workflow-00c-openalex-ingestion` | `3a6367b40859f1784fc7dd22286988cb329e8c05` | `validated-workflow00-openalex-2026-09-22` |
| AGRICOLA | `updater-workflow-00d-agricola-ingestion` | `b4854bc3c52bfc48d3596bb35057ffe4b86737fa` | `validated-workflow00-agricola-2026-09-22` |
| WoS | `updater-workflow-00e-wos-starter-ingestion` | `eddc6e929e0f776937e56dfd40d9bdfbb72786ea` | `validated-workflow00-wos-2026-09-22` |

The commit SHAs above are the provenance authority. The frozen branches are convenience pointers to those immutable commits.

## Important validated behaviour

- Fortnightly Lens, Scopus, AGRICOLA and WoS source-specific incremental logic is retained.
- OpenAlex fortnightly searching is restricted to the current and following publication year; full and expansion searches remain unrestricted.
- OpenAlex raw API pages remain unmodified.
- Exact repeated OpenAlex Work IDs caused by live-index cursor drift are recorded and deterministically collapsed before identifier-delta comparison.
- AGRICOLA zero-result fortnightly harvests are valid and do not fail sidecar adaptation.
- Search records, source harvest artefacts and consolidated search archive generation passed.

## Production promotion rule

Do not reconstruct Workflow 00 from memory and do not selectively copy files from old branches.

When the entire pipeline is validated:

1. Compare each active implementation branch against the exact validated commit listed above.
2. Review any changes made after validation.
3. Consolidate the required source implementations and shared orchestration into the production branch.
4. Run the complete pipeline from search through final outputs on the candidate production branch.
5. Only after that complete run passes, merge/promote to `main`.
6. Remove obsolete standalone search workflows only after the production pipeline is verified on `main`.
7. Keep these frozen branches until the production merge and a subsequent scheduled run have both passed.

## Scope

This snapshot certifies **Workflow 00 search/update behaviour only**. It does not certify downstream Workflow 01+ stages unless a later validated-pipeline manifest explicitly says so.
