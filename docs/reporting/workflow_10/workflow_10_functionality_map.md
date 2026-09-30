# Workflow 10: interactive dashboard and public evidence-map interface

## Purpose

Workflow 10 is the public interactive presentation layer of the LivingEvidenceMap pipeline. It restores the authoritative Workflow 08 included-only canonical evidence base and projects it into a static browser-based dashboard without altering screening, deduplication, species, geography or topic decisions.

The dashboard is a derived presentation layer rather than an analytical authority. The Workflow 08 canonical JSONL remains the definitive record-level evidence base, while Workflow 09 remains the authoritative manuscript/reporting layer.

The accepted final W10 architecture provides:

1. headline evidence-map metrics;
2. geographic distribution and country filtering;
3. publication-year summaries;
4. species-by-topic views;
5. a navigable hierarchical topic visualisation;
6. an interactive bibliographic database with species, country, year and topic filters; and
7. links to the methodological and results reports.

A title/abstract search and RIS-download interface was developed and validated during W10 development. Its underlying implementation is retained for possible future reactivation, but the public entry button is deliberately hidden in the accepted final dashboard.

Keyword enrichment is **not part of Workflow 10**. The final dashboard does not depend on author keywords, indexing terms or any future keyword-retrieval process.

This document is intended to serve two purposes:

1. as a methodological guide to the repository implementation; and
2. as source text for reporting the workflow in a research paper.

## Functionality map

```text
[authoritative Workflow 08 included-only canonical JSONL]
                         |
                         v
          [checksum-validated restoration]
                         |
                         v
             [W10 dashboard projection]
                         |
         +---------------+----------------+
         |               |                |
         v               v                v
 [bibliographic]    [geography]      [topic hierarchy]
   metadata          + species        + star support
         |               |                |
         +---------------+----------------+
                         |
                         v
              [static dashboard data]
                         |
                         v
                [browser interface]
                         |
       +-----------------+------------------+
       |                 |                  |
       v                 v                  v
   KPI summary       interactive        filtered
   and charts          figures          database
       |
       v
 [public GitHub Pages dashboard]

Optional retained but inactive branch:
[title/abstract search + RIS export implementation]
                         |
                         v
           [public entry button hidden]
```

## Components

| Component | Function |
|---|---|
| `.github/workflows/workflow_10_dashboard.yml` | Production controller that restores and validates the authoritative Workflow 08 canonical JSONL and builds the dashboard projection. |
| `scripts/updater/workflow_10_restore_canonical_from_zenodo.R` | Restores the registered authoritative W08 canonical archive and verifies its provenance/checksum. |
| `R/workflow_10_dashboard_from_canonical_jsonl.R` | Converts the included canonical JSONL into the static dashboard data projection and summary metrics. |
| `docs/dashboard-redesign-temp.html` | Core dashboard presentation template used during W10 development and preview deployment. |
| `docs/dashboard-search-trial.html` | Accepted final dashboard template containing the later database/search interface implementation; the search/download opener is hidden in the final public presentation. The historical filename is retained to avoid unnecessary refactoring of a validated implementation. |
| `R/workflow_10_build_search_trial.R` | Builds the lightweight browser payload and positional abstract index used by the optional search/download implementation. |
| `.github/workflows/workflow_10_search_trial.yml` | Validates the search/download implementation and associated data/index artefacts. |
| `.github/workflows/workflow_10_pages_preview.yml` | Deploys an isolated W10 Pages preview while preserving the production site. |
| `docs/dashboard-topic-definitions.json` | Dashboard-only explanatory definitions for higher-level topic nodes. |
| `data/reference/topic_ontology_v3_6.csv` | Frozen topic ontology used to validate and label W08/W07 topic pathways. |
| `config/iso3_numeric_map.json` and `config/global_country_gazetteer_v3.csv` | Country-code mappings used for geographic presentation. |
| `docs/reporting/workflow_09/flow_counts.json` | Reporting-layer source for search, deduplication and screening headline metrics displayed by W10. |

## Inputs and methodological rules

### Authoritative evidence input

Workflow 10 consumes the definitive **19,117-record included-only Workflow 08 canonical JSONL**.

The accepted baseline is the restricted Zenodo record:

- Zenodo record: **23020526**;
- DOI: `10.5281/zenodo.23020526`;
- canonical SHA-256:  
  `8a42fe35f3c08bb4cd80824e494b9b579797a2c83286799b999aa9024ce9bb8c`.

The dashboard build rejects unexpected schema versions, duplicate record IDs, non-included records, unknown topic paths and malformed topic-support values.

Workflow 10 never modifies the canonical JSONL.

### Dashboard projection

For each included record, W10 projects the fields needed for public exploration:

- stable canonical record ID;
- title;
- abstract or permitted abstract representation for the relevant interface;
- DOI;
- publication year;
- authors;
- journal;
- volume and pages;
- final species labels;
- final country/ISO3 assignments;
- retained topic pathways;
- Workflow 07 topic-support stars; and
- topic path identifiers.

The projection is deliberately narrower than the canonical record. Nested provenance, screening internals, model outputs and adjudication state remain in the authoritative W08 JSONL.

### Species

The dashboard consumes the final post-W08 species layer. Species filters are intersective with other dashboard filters rather than independent views.

The dashboard display order is fixed for the focal farmed species categories and the unspecified-salmon category.

### Geography

Country visualisation uses final W08 geography assignments and validated ISO3 mappings. Country counts represent unique included records associated with each country.

Country selection in the map or database is propagated to the same shared filter state.

### Topics

Workflow 10 uses final retained topic pathways from W07/W08 and the frozen v3.6 ontology.

Topic support is displayed using the preserved three-pass model-agreement convention:

- ★ = one of three passes;
- ★★ = two of three passes;
- ★★★ = three of three passes.

Higher-level dashboard topic definitions are presentation metadata only. They do not change the ontology or record-level topic assignments.

### Keywords

Keywords are intentionally excluded from the accepted W10 architecture.

Neither author keywords nor database indexing terms are required for:

- dashboard filtering;
- topic assignment;
- geographic analysis;
- species analysis;
- publication-year analysis;
- bibliographic display; or
- future W10 regeneration.

Keyword repair/enrichment is therefore not a W10 dependency and should not block future dashboard updates.

### Search/download implementation

A richer browser-side title/abstract search and filtered RIS-download interface was developed and validated as part of W10.

For that implementation:

- the main public data payload contains only the first up-to-30 words of each abstract;
- a separate positional inverted index supports browser-side abstract searching and reconstruction for the optional export function;
- Boolean `AND`, `OR`, `NOT`, parentheses, phrases and wildcard matching were implemented;
- RIS export is limited to the filtered subset.

For the accepted final dashboard, the **Search and download** opener is hidden using a presentation-only CSS rule. The underlying implementation is retained unchanged so it can be re-enabled later without reconstructing the feature.

Hiding the control does not alter any other W10 functionality.

## Processing modes or stages

### 1. Restore the authoritative W08 canonical state

The W10 production workflow resolves the registered authoritative W08 pointer and verifies:

- Zenodo record identity;
- DOI;
- canonical JSONL checksum; and
- expected record schema.

The source file is restored only after these checks pass.

### 2. Build the dashboard data projection

`R/workflow_10_dashboard_from_canonical_jsonl.R` reads the canonical JSONL record by record and validates:

- exactly 19,117 included records;
- unique stable record IDs;
- valid species labels;
- structured geography fields;
- valid topic path IDs;
- agreement between topic IDs and ontology hierarchy paths; and
- valid 1–3 star topic-support values.

It then builds:

- record-level dashboard data;
- species counts;
- country counts;
- country-by-species counts;
- hierarchical topic counts;
- topic definitions;
- map lookup data; and
- headline evidence-flow metrics.

### 3. Render the interactive interface

The browser interface exposes the projection through coordinated views.

The accepted final dashboard includes:

- headline KPIs;
- geographic distribution map;
- publication-year chart;
- topic-assignment frequency by species;
- species × topic heat-map navigation;
- radial topic hierarchy;
- database table;
- species filter;
- country filter;
- publication-year filter;
- topic filter;
- record-page-size control;
- filter reset; and
- sortable bibliographic columns.

Selections made in figures can be used to jump directly to the database under the corresponding filter state.

### 4. Optional search/download layer

The validated search/download layer derives a browser-safe dashboard payload and positional abstract index from the same W08 canonical state.

This branch remains technically present but is **inactive in the accepted final public interface** because its opener is hidden.

### 5. Static deployment

W10 is deployed as static HTML/JavaScript through GitHub Pages. It requires no application server or live database.

The final hidden-button implementation was validated in GitHub Actions run **36747709725** and deployed successfully through the lightweight Pages deployment in run **36752942486**.

## Provenance and documentation

Workflow 10 records or validates, as applicable:

- authoritative W08 Zenodo record ID and DOI;
- source canonical JSONL SHA-256;
- source GitHub Actions run identity;
- ontology path and version;
- dashboard-generation timestamp;
- output record count;
- topic-assignment count;
- records without topic assignments;
- country count;
- species-category count;
- dashboard data SHA-256;
- search-trial dashboard-data SHA-256;
- search-trial abstract-index SHA-256;
- public data/index file sizes;
- Git commit;
- validation run; and
- deployment run.

Current accepted presentation baseline:

- hidden search/download button commit on W10 branch:  
  `36d0f72dc4b69dd6acddc5e811f2b54e42bb951a`;
- W10 validation run: **36747709725**;
- lightweight final Pages deployment run: **36752942486**.

## Storage and archival model

### Permanent repository records

GitHub retains:

- W10 R build scripts;
- W10 workflow definitions;
- dashboard HTML templates;
- topic-definition presentation metadata;
- geographic lookup configuration;
- this methodological report; and
- the W10 status README.

The accepted hidden-button rule is retained in version control rather than deleting the search/download implementation.

### Short-lived GitHub Actions artefacts

W10 build/validation runs may retain:

- generated dashboard JavaScript;
- flat dashboard CSV;
- dashboard-data manifest;
- optional search-trial data payload;
- positional abstract index;
- search-trial manifest; and
- assembled preview files.

These are operational outputs rather than the authoritative evidence record.

### Durable external archive

Workflow 10 does not create a separate Zenodo evidence archive.

The durable analytical source remains the Workflow 08 Zenodo archive. W10 can be regenerated from that canonical state plus the version-controlled dashboard implementation.

## Downstream handoff

Workflow 10 is the public presentation endpoint of the pipeline and has no analytical downstream workflow.

Future living-evidence updates should regenerate W10 only after a new W08 state has been validated and made authoritative. The dashboard architecture itself is considered frozen: routine updates should replace the data projection and headline metrics while preserving the accepted interface and interaction model unless a deliberate redesign is initiated.

Keyword enrichment is not required before such an update.

The hidden search/download implementation may be reactivated deliberately by removing the visibility rule from the opener control; doing so is a presentation decision and does not require rebuilding the underlying evidence pipeline.

## Methods text for research reporting

> **Workflow 10: interactive evidence-map dashboard.** The final included canonical evidence base was projected into a static interactive dashboard after checksum validation of the authoritative post-adjudication dataset. Record-level bibliographic metadata were combined with final species, geography and hierarchical topic annotations to support linked geographic, temporal, species and topic summaries and an interactive filtered database. Topic assignments retained their three-pass model-agreement indicators. The dashboard was implemented as static HTML and JavaScript and deployed through GitHub Pages, while the provenance-preserving canonical JSONL remained the authoritative analytical record. Dashboard generation did not modify screening or annotation decisions and did not depend on keyword enrichment.

## Reporting status

Workflow 10 is considered complete and validated when:

- the authoritative W08 pointer and canonical checksum are verified;
- exactly 19,117 included records are represented for the current baseline;
- stable record identity is preserved;
- final species, geography and topic fields are projected without recoding;
- topic pathways and model-support stars validate against the frozen ontology;
- coordinated dashboard filters and visualisations function against the same record population;
- generated dashboard outputs pass structural validation;
- the accepted public presentation deploys successfully;
- the search/download opener is hidden while the underlying optional implementation remains recoverable; and
- keyword enrichment is not treated as a W10 dependency.

These conditions are satisfied for the accepted 30 September 2026 baseline.

**Workflow 10 status: complete, validated and locked as the final dashboard architecture.**
