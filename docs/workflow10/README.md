# Workflow 10 - interactive dashboard

Workflow 10 is the final public presentation layer of the LivingEvidenceMap pipeline.

The full methodological report is:

`docs/reporting/workflow_10/workflow_10_functionality_map.md`

## Final accepted architecture

The dashboard is locked to the implementation validated on 30 September 2026.

It uses the authoritative Workflow 08 included-only canonical JSONL and presents:

- headline evidence-map metrics;
- geography and country filtering;
- publication-year summaries;
- species-by-topic summaries;
- hierarchical topic navigation;
- model-agreement stars for topic assignments; and
- an interactive filtered bibliographic database.

The historically named `docs/dashboard-search-trial.html` is the accepted final dashboard template. Its **Search and download** opener is intentionally hidden. The underlying search/download implementation is retained so it can be restored later without rebuilding the feature.

## Keywords

Keyword enrichment is not part of the final Workflow 10 architecture.

W10 does not require author keywords or database indexing terms for its figures, filters, database or future living updates. Keyword retrieval should therefore not block W10 regeneration.

## Accepted validation/deployment

- W10 hidden-button validation: run **36747709725**.
- Lightweight final Pages deployment: run **36752942486**.
- Authoritative W08 baseline: **19,117 included records**.
- W08 canonical SHA-256:  
  `8a42fe35f3c08bb4cd80824e494b9b579797a2c83286799b999aa9024ce9bb8c`.

Future W10 runs should update the dashboard from a newly validated authoritative W08 state while preserving this interface unless a deliberate redesign is approved.
