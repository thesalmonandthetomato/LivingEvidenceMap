# Workflow 10: interactive dashboard and public evidence-map interface

## Purpose

Workflow 10 is the final presentation and output-cataloguing endpoint of the LivingEvidenceMap pipeline. It restores the latest authoritative Workflow 08 included-only canonical evidence base after successful Workflow 09 publication, validates its provenance, projects it into a static browser-based dashboard, and writes an internal repository-only output registry archived by search date.

Workflow 10 does not modify deduplication, screening, species, geography or topic decisions. The Workflow 08 canonical JSONL remains the authoritative record-level analytical dataset, while Workflow 09 remains the authoritative reporting and manuscript layer.

The accepted Workflow 10 interface provides:

1. headline evidence-map metrics;
2. geographic distribution and country filtering;
3. publication-year summaries;
4. topic-assignment summaries by species;
5. hierarchical topic exploration;
6. an interactive bibliographic database table with coordinated filters; and
7. links to the rendered Methods and Results reports.

A title/abstract search and filtered RIS-download feature was developed during W10 development but is **not part of the current production architecture**. Its implementation is retained as a manual restoration path only. Production W10 does not build the abstract inverted index, does not reconstruct full abstracts, and does not generate the browser-side RIS download.

This document serves two purposes:

1. as a methodological guide to the repository implementation; and
2. as source text for reporting the workflow in a research paper.

## Functionality map

```text
[authoritative Workflow 08 final canonical JSONL]
                         |
                         v
              [Workflow 09 publication]
                         |
                         | successful validation + publication
                         v
 [docs/reporting/.run_workflow10_dashboard]
                         |
                         v
             [Workflow 10 production]
                         |
            +------------+-------------+
            |                          |
            v                          v
 [restore + verify W08]       [validate W09 handoff]
            |                          |
            +------------+-------------+
                         |
                         v
          [internal dashboard projection]
                         |
                         v
             [public table projection]
                         |
       +-----------------+------------------+
       |                 |                  |
       v                 v                  v
   KPI/charts       linked filters     bibliographic
 + visualisations   + navigation       database table
       |                 |                  |
       +-----------------+------------------+
                         |
                         v
            [static W10 Pages artefact]
                         |
                         v
              [public presentation]

In parallel after validation:
             [internal output registry]
                         |
                         v
 [internal/output_registry/archive/YYYY-MM-DD/]
                         |
          +--------------+--------------+
          |              |              |
          v              v              v
       HTML            JSON            CSV
        + manifest/checksums + Zenodo catalogue

Retained restoration path only:
[dashboard-search-trial.html + workflow_10_build_search_trial.R]
                         |
                         v
        [manual-only search/RIS workflow]
```

## Components

| Component | Function |
|---|---|
| `.github/workflows/workflow_10_dashboard.yml` | Production W10 controller. Restores and validates the authoritative W08 state, validates the W09 handoff, builds the internal and public dashboard projections, validates the public interface, updates live pipeline status and uploads the W10 artefact. |
| `scripts/updater/workflow_10_restore_canonical_from_zenodo.R` | Restores the registered authoritative W08 canonical archive and verifies the downloaded canonical file against the registered pointer. |
| `R/workflow_10_dashboard_from_canonical_jsonl.R` | Builds the complete internal W10 dashboard projection and aggregate metrics from the authoritative canonical JSONL. |
| `R/workflow_10_make_public_dashboard.R` | Converts the internal projection into the public database-table payload. It removes full abstracts, replaces them with a maximum 30-word snippet, and asserts that search/RIS/index functionality is disabled. |
| `docs/index.html` | Accepted W10 dashboard interface on the workflow branch. The database table and all ordinary table/filter interactions remain present; search/download controls are absent. |
| `docs/dashboard-search-trial.html` | Preserved reference implementation containing the previously developed search/download interface. It is not the production W10 template. |
| `R/workflow_10_build_search_trial.R` | Preserved builder for the retired browser-side abstract search/index/RIS feature. Not called by production W10. |
| `.github/workflows/workflow_10_search_trial.yml` | Manual-only restoration/test workflow for the retired search/download functionality. It no longer auto-triggers. |
| `docs/dashboard-topic-definitions.json` | Dashboard-only definitions for higher-level topic nodes. These do not alter the analytical ontology. |
| `user_input/workflow07_topic_ontology.csv` | Current controlled topic ontology used to validate retained W07/W08 topic pathways. |
| `config/iso3_numeric_map.json` | Mapping between ISO3 country codes and numeric map identifiers. |
| `config/global_country_gazetteer_v3.csv` | Country-name lookup used for dashboard presentation. |
| `docs/reporting/workflow_09/flow_counts.json` | Authoritative reporting-layer source for headline search, deduplication and screening metrics. |
| `docs/reporting/.run_workflow10_dashboard` | Dedicated W09→W10 provenance trigger. Its update is the production handoff event from successful W09 publication to W10. |
| `scripts/updater/workflow_current_run_status_observer.R` | Tracks W09 and W10 start/completion states for the current-run progress display. |
| `scripts/updater/workflow_current_run_status_to_shiny.R` | Writes the current-run status to the Shiny backing store. |
| `scripts/reporting/workflow_10_build_internal_output_registry.R` | Builds the internal output registry from current-run search provenance, workflow Zenodo registries, reporting outputs, codebooks and W10 artefacts. Enforces restricted Zenodo visibility and writes dated HTML/JSON/CSV plus a checksum manifest. |
| `internal/output_registry/archive/YYYY-MM-DD/` | Durable repository archive of the internal output registry for each search date. Stored outside `docs/` so it is not part of the public dashboard deployment bundle. |

## Inputs and methodological rules

### Authoritative evidence input

Workflow 10 does not use a hard-coded release count or canonical checksum.

For each run it resolves the single row marked `authoritative` in:

`docs/workflow08/zenodo_registry.csv`

and then resolves the corresponding published pointer under:

`docs/workflow08/zenodo/`

The pointer supplies the current:

- authoritative Workflow 08 source run;
- Zenodo record;
- DOI;
- canonical record count;
- excluded-record count; and
- final canonical JSONL SHA-256.

The restored canonical JSONL is accepted only when its checksum matches the authoritative pointer.

For the current validated release, the authoritative input is:

- Workflow 08 source run: **37234697766**;
- Zenodo record: **23145712**;
- DOI: `10.5281/zenodo.23145712`;
- included records: **21,493**; and
- canonical SHA-256: `96a854952aecf3a562fadf603670f650fa26ba9974c819e4b98f9c4dc4f6de20`.

These values document the current release but are not embedded as production gates in W10.

### Workflow 09 handoff

Production W10 begins only after successful Workflow 09 publication.

Workflow 09 writes:

`docs/reporting/.run_workflow10_dashboard`

after its publication package has passed validation, been committed, and its live W09 status has been updated. The trigger records Workflow 09 provenance and causes one branch-native W10 run.

W10 no longer relies on incidental changes to W08 pointers, W09 flow-count files or W09 compact handoff files to start a production build. This prevents dashboard generation from starting while W09 is still writing its publication package.

### Internal dashboard projection

`R/workflow_10_dashboard_from_canonical_jsonl.R` validates and projects the final included canonical population.

The internal projection contains the fields required for W10 rendering and validation, including:

- stable canonical record ID;
- title;
- full abstract within the runner-only internal projection;
- DOI;
- publication year;
- authors;
- journal;
- volume and pages;
- final species labels;
- final countries and ISO3 codes;
- retained topic paths;
- Workflow 07 topic-support stars;
- topic-support counts;
- topic path IDs; and
- topic-finalisation provenance.

This internal projection is runner-only and is not uploaded as the public W10 artefact.

### Public database-table projection

The public projection preserves the accepted bibliographic database table while removing the retired search/download data requirements.

For each included record, the public dashboard contains the table fields required to render and filter the database, including:

- stable record ID used by the browser interface;
- title;
- DOI;
- publication year;
- authors;
- journal;
- volume and pages;
- species;
- countries and ISO3 codes;
- topic paths and topic-support stars; and
- an abstract snippet of at most 30 words.

It does **not** contain the full abstract field.

The public projection explicitly records:

- `database_table = true`;
- `full_abstracts = false`;
- `abstract_snippet_words = 30`;
- `search = false`;
- `ris_download = false`; and
- `abstract_index = false`.

### Species

W10 consumes final post-W08 species labels. Species selection is coordinated with country, publication-year and topic filters in the database table and with the relevant dashboard figures.

No species inference or recoding occurs in W10.

### Geography

W10 uses final post-W08 country and ISO3 assignments.

Map and table interactions operate on the same final geography layer. The production build uses the controlled ISO3 mapping and country gazetteer for presentation only; it does not re-adjudicate geography.

### Topics

W10 uses final retained topic pathways and Workflow 07 agreement values carried through W08.

The dashboard displays three-pass support using:

- ★ = one supporting pass;
- ★★ = two supporting passes; and
- ★★★ = three supporting passes.

Dashboard-only higher-level definitions are explanatory presentation metadata and do not modify the controlled topic ontology.

### Search and RIS download

Search/download is deliberately excluded from production W10.

Production W10 therefore does not:

- expose a title/abstract search interface;
- build a positional abstract index;
- expose full abstracts;
- reconstruct abstracts in the browser;
- produce a filtered browser-side RIS file; or
- upload the search-trial manifest/index.

The previously validated implementation remains preserved in version control and can be restored deliberately through the manual-only search-trial workflow.

### Keywords

Keyword enrichment is not a W10 dependency.

Author keywords and database indexing terms are not required for:

- dashboard filtering;
- topic visualisation;
- species visualisation;
- geography visualisation;
- publication-year visualisation; or
- bibliographic table rendering.

Keyword retrieval therefore does not block W10 regeneration.

## Processing modes or stages

### 1. Receive the W09 handoff

A successful W09 run commits the dedicated W10 trigger file only after W09 validation and publication complete.

W10 also remains manually dispatchable for independent reproduction and testing.

A concurrency group prevents overlapping W10 builds from racing; later builds wait rather than cancelling the active production build.

### 2. Mark W10 active

At the beginning of W10, the current-run status is updated so the Shiny progress display shows:

- W09 complete; and
- W10 active.

This status is written before the substantive W10 build begins.

### 3. Resolve the authoritative W08 state

W10 reads the authoritative W08 registry and pointer, verifies that exactly one authoritative state is registered, and checks pointer status and provenance.

No release-specific record count or SHA is hard-coded in the production workflow.

### 4. Validate the W09 reporting handoff

Before building the dashboard, W10 checks the current W09 publication handoff against the authoritative W08 pointer, including:

- W08 source run identity;
- final canonical SHA-256;
- included-record count; and
- excluded-record count.

The dashboard therefore cannot silently combine a current W08 canonical state with a stale W09 reporting package.

### 5. Restore the authoritative W08 canonical JSONL

The canonical JSONL is restored from the registered restricted Zenodo record using the workflow credential.

The restored file is temporary runner state and is not committed or uploaded as part of W10.

### 6. Build the internal W10 projection

The internal builder reads the canonical JSONL record by record and validates:

- canonical schema;
- unique stable record IDs;
- final inclusion status;
- final species labels;
- geography structure;
- topic path IDs;
- agreement between topic IDs and ontology paths; and
- valid 1–3 star topic-support values.

It generates the complete runner-only dashboard projection and the flat internal validation CSV.

### 7. Build the public table projection

The public projection step reproduces the accepted database-table payload but removes full abstracts.

Each full abstract is replaced with its first up-to-30 whitespace-delimited words, adding an ellipsis only when truncation occurs.

The builder verifies record-by-record that:

- no full `abstract` field survives;
- every `abstract_snippet` matches the canonical source;
- no snippet exceeds 30 words; and
- all required table fields remain present.

### 8. Validate the dashboard interface

The W10 workflow requires the final HTML to retain:

- the database section;
- species filter;
- country filter;
- publication-year filter;
- topic filter;
- database table body;
- chart-to-database filtering language and interaction structure; and
- the production dashboard data script.

It also requires search/download-specific UI and artefacts to be absent.

### 9. Build and archive the internal output registry

After the dashboard has passed validation, W10 generates an internal registry under:

`internal/output_registry/archive/YYYY-MM-DD/`

where the directory name is the current search date.

The registry contains:

- database/source search dates and result counts;
- Workflow 00–08 Zenodo records;
- stage descriptions, source run IDs, archive state and publication timestamps;
- Zenodo DOIs displayed as the DOI string itself, for example `10.5281/zenodo.23117851`, with the DOI resolver as the hyperlink target;
- reports, RIS exports, figures, codebooks, validation outputs and compact workflow-reporting inputs;
- W10 build artefacts;
- file sizes; and
- SHA-256 checksums.

The registry consists of:

- `output-registry.html`;
- `output-registry.json`;
- `output-registry-files.csv`; and
- `manifest.json`.

This archive is internal to the repository and is not included in the Pages/public-dashboard artefact. All workflow Zenodo deposits are expected to be restricted. The registry builder fails if it encounters a workflow Zenodo record whose visibility is not `restricted`. W10 does not create or advertise a separate public-release Zenodo record.

### 10. Upload the W10 artefact

The production W10 artefact contains only:

- `index.html`; and
- `dashboard-data.js`.

It does not upload:

- the restored canonical JSONL;
- the runner-only internal CSV;
- the runner-only internal JS projection;
- an abstract index;
- a search-trial manifest; or
- a separate browser-generated RIS database.

### 11. Mark W10 complete

After successful W10 validation and artefact upload, the current-run status is updated so W10 is complete and no workflow remains active.

The resulting status metadata are committed back to the workflow branch.

### 12. Static Pages deployment

W10 is designed for static GitHub Pages deployment and requires no application server.

While the workflow architecture remains on `workflow01-final-architecture`, the validated dashboard can be tested without replacing the existing public homepage by publishing it on `main` as:

- `docs/index2.html`; plus
- deployment-only `index2-data.js`.

The same preview bundle can expose the validated W09 HTML as:

- `methodology.html`; and
- `results.html`.

The preview deployment does not alter the existing `docs/index.html` homepage.

## Provenance and documentation

Each W10 run validates or records:

- W10 GitHub Actions run ID;
- upstream W09 trigger provenance;
- authoritative W08 source run;
- W08 Zenodo record and DOI;
- source canonical SHA-256;
- included and excluded record counts;
- topic ontology source;
- current W09 reporting handoff;
- public projection schema;
- public record count;
- topic-assignment support;
- absence of full abstracts;
- 30-word abstract-snippet constraint;
- database-table presence;
- search/RIS/index absence;
- uploaded artefact composition;
- internal output-registry search date;
- internal registry file checksums;
- Workflow 00–08 Zenodo DOI, state, source run and restricted visibility;
- current-run W10 start/completion state; and
- Git commit associated with the build.

Current validation milestones are:

- restored database-table production W10: run **37278806375**;
- W10 hardening without release-specific gates: run **37280449723**;
- explicit W09→W10 trigger validation: run **37280725369**;
- W09 Methods/Results plus W10 `index2` Pages preview: run **37280303397**; and
- dated internal output-registry generation, validation and repository archival: run **37461142844**.

## Storage and archival model

### Permanent repository records

The workflow branch retains:

- production W10 R scripts;
- W10 workflow definitions;
- accepted dashboard HTML;
- presentation metadata and lookup files;
- the dedicated W09→W10 trigger record;
- the preserved manual search/download restoration implementation;
- W10 methodological documentation;
- W10 status documentation; and
- dated internal output registries under `internal/output_registry/archive/YYYY-MM-DD/`.

The public database table remains part of the production interface.

### Short-lived GitHub Actions artefacts

Each W10 production run uploads the validated static dashboard bundle containing:

- `index.html`; and
- `dashboard-data.js`.

The artefact is an operational/publication bundle, not the authoritative analytical dataset.

The full restored canonical JSONL and internal full-abstract dashboard projection remain runner-only.

### Durable archives

Workflow 10 creates no separate Zenodo evidence archive.

The authoritative analytical dataset remains the restricted Workflow 08 Zenodo canonical archive. W10 is fully regenerable from that canonical state, the validated W09 reporting handoff and the version-controlled W10 implementation.

W10 does, however, create a durable **internal repository archive** of output registries, keyed by search date. This catalogue is provenance/documentation metadata rather than a replacement analytical dataset. It is intentionally excluded from the public Pages bundle.

## Downstream handoff

Workflow 10 is the final public-presentation stage and has no downstream analytical workflow.

The production orchestration chain is:

```text
W08 final publication
        |
        v
W09 reporting/publication
        |
        v
dedicated W09→W10 trigger
        |
        v
W10 dashboard
```

Routine living updates should regenerate W10 only after a new W08 canonical state has passed W09 publication validation.

The dashboard interface is treated as locked for routine updates. Future updates should replace the underlying authoritative data projection while preserving the accepted interactions and table design unless a deliberate redesign is approved.

The search/download/RIS implementation can be restored only by an explicit future decision; its manual restoration path is retained but separated from production orchestration.

## Methods text for research reporting

> **Workflow 10: interactive evidence-map dashboard.** Following successful generation of the reporting package, the final included canonical evidence base was restored from its checksum-validated authoritative archive and projected into a static interactive dashboard. Final bibliographic metadata, species assignments, geography and hierarchical topic annotations were combined to support coordinated geographic, temporal, species and topic visualisations and a filterable bibliographic database. Full abstracts were excluded from the public dashboard payload and represented in the database only by snippets of up to 30 words. A previously developed browser-side title/abstract search and filtered RIS-export implementation was retained separately but disabled from the production workflow. Dashboard generation was deterministic, did not modify any screening or annotation decisions, and was deployed as static HTML and JavaScript while the provenance-preserving Workflow 08 canonical JSONL remained the authoritative analytical record.

## Reporting status

Workflow 10 is considered complete and validated when:

- a successful Workflow 09 publication explicitly triggers W10;
- the single authoritative W08 pointer is resolved dynamically;
- the restored canonical checksum matches that pointer;
- the W09 publication handoff matches the same authoritative W08 state;
- the complete final included population is represented;
- stable record identity is preserved;
- final species, geography and topic fields are projected without recoding;
- topic pathways and support stars validate against the controlled ontology;
- the accepted database table and its species, country, year and topic filters remain present;
- chart and topic interactions continue to filter or navigate to the database;
- public abstracts are limited to at most 30-word snippets;
- no full abstract field is exposed in the public payload;
- no search panel, abstract index or W10-generated RIS download is produced;
- the W10 artefact contains only the validated public HTML and JavaScript payload;
- the internal output registry is generated under the search-date archive directory;
- all workflow Zenodo records listed in the registry are restricted;
- DOI display text uses the DOI itself rather than a generic label;
- the internal registry is not included in the Pages/public-dashboard artefact;
- W10 start and completion are reflected in current-run status; and
- static Pages deployment succeeds.

These conditions have been validated for the current release. Run **37278806375** validated the restored database-table architecture, run **37280449723** validated the hardened dynamic W10 workflow, run **37280725369** validated the dedicated automatic W09→W10 handoff, and run **37461142844** validated the internal dated output-registry build and archival step.

**Workflow 10 status: complete, validated and locked on `workflow01-final-architecture` pending final integration to `main`.**
