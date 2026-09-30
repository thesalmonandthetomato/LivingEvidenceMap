# Workflow 09: reporting, publication outputs and reference-library export

## Purpose

Workflow 09 is the final reporting and publication stage of the LivingEvidenceMap pipeline. It does not alter screening or annotation decisions. Instead, it restores the latest authoritative Workflow 08 included-only canonical dataset and the upstream provenance states needed for reporting, then produces a reproducible publication package consisting of:

1. a lightweight RIS representation of the complete included canonical library;
2. manuscript figures and their exact R source code;
3. Methods and Results source documents;
4. rendered Markdown, HTML, Word and PDF manuscript outputs; and
5. the compact data products needed to audit reported counts and figures.

The authoritative analytical data remain the Workflow 08 canonical JSONL. Workflow 09 is a derived reporting layer.

## Functionality map

```text
[latest authoritative Workflow 08 canonical JSONL]
                         |
                         +------------------------------+
                         |                              |
                         v                              v
                [RIS export]                   [reporting data layer]
              current included corpus                  |
                         |                              |
                         |                 +------------+-------------+
                         |                 |                          |
                         |                 v                          v
                         |        [manuscript figures]       [dynamic Results text]
                         |                 |                          |
                         |                 +------------+-------------+
                         |                              |
                         v                              v
              [docs/.../data/*.ris]       [Methods + Results publication set]
                                                    |
                              +---------------------+----------------------+
                              |                     |                      |
                              v                     v                      v
                         Markdown/HTML             Word                   PDF
                              |
                              v
              [version-controlled Workflow 09 package]
```

Workflow 09 additionally restores the authoritative Workflow 01 and Workflow 02 states where they are required for source-contribution and review-flow reporting. Final inclusion IDs and exclusions come from Workflow 08, so database-contribution reporting reflects the definitive included corpus rather than an intermediate screening state.

## Components

| Component | Function |
|---|---|
| `.github/workflows/report_workflow09_figures.yml` | Production controller for restoration, RIS export, figure generation, manuscript rendering, validation and publication to the branch. |
| `scripts/reporting/export_canonical_ris.R` | Converts every included canonical JSONL record to a portable RIS representation. |
| `visualisations/canonical_figure_data.R` | Loads and flattens the final canonical JSONL for reporting figures. |
| `visualisations/01_records_by_publication_year.R` | Publication year × species figure. |
| `visualisations/02_records_by_country.R` | Country × species figure. |
| `visualisations/03_choropleth_records_by_country.R` | Global country choropleth. |
| `visualisations/04_topic_hierarchy.R` | High-level topic figure and seven theme-specific hierarchy figures. |
| `visualisations/05_records_by_publication_year_high_level_topic.R` | Publication year × high-level topic figure. |
| `visualisations/07_flow_diagram.R` | Review/process flow figure and machine-readable flow counts. |
| `visualisations/08_umbrella_review_figure.R` | Comparison with the supplied umbrella-review dataset. |
| `scripts/reporting/plot_citesource_database_contribution.R` | Paired database-contribution/overlap figure before and after relevance screening. |
| `docs/reporting/workflow_09/manuscript/long_form_methods.Rmd` | Version-controlled Methods source. |
| `docs/reporting/workflow_09/manuscript/long_form_results.Rmd` | Version-controlled Results source with values calculated from the current reporting state. |
| `docs/reporting/workflow_09/figures/` | Permanent PNG and PDF publication figures, numbered in manuscript order. |
| `docs/reporting/workflow_09/figure_code/` | Snapshot of the exact R plotting code used for the permanent figure set. |
| `docs/reporting/workflow_09/data/` | RIS export and export manifest. |

## Authoritative inputs

### Final included corpus

Workflow 09 restores the latest registered authoritative Workflow 08 Zenodo pointer from `docs/workflow08/zenodo/`. The restored canonical JSONL is accepted only when its SHA-256 and record count match that pointer. This makes reporting advance automatically with a newly published Workflow 08 state rather than remaining pinned to a historical baseline.

The final Workflow 08 JSONL remains the authoritative representation because it preserves nested workflow provenance, screening state, species coding, geography coding, topic assignments and manifestation references.

### Upstream reporting states

Some figures require information that is intentionally not duplicated into the included-only final JSONL. Workflow 09 therefore restores:

- Workflow 01 canonical/source-provenance state for database-contribution analysis;
- Workflow 02 cumulative enrichment state for record-repair counts;
- Workflow 08 final included record IDs for after-screening source contribution; and
- Workflow 08 exclusions for final flow accounting.

Stable `record_id` values are used to reconcile these reporting layers.

## RIS export

Workflow 09 exports the complete included canonical population to:

`docs/reporting/workflow_09/data/living_evidence_map_canonical_final.ris`

The RIS contains one entry for every included canonical record and retains the portable bibliographic and analytical fields that can be represented usefully in RIS:

- canonical record ID;
- title;
- authors;
- publication year;
- journal;
- volume;
- issue;
- pages;
- DOI and DOI URL;
- abstract;
- final species labels;
- final country names; and
- retained topic pathways, including Workflow 07 star support where present in the canonical assignment.

The RIS deliberately does not attempt to serialise the full nested workflow audit structure, deduplication internals or manifestation-level provenance into free-text RIS notes. Those data remain authoritative in the JSONL. The RIS is therefore a **complete-record, lightweight bibliographic export**, not a replacement for the canonical JSONL.

A JSON manifest beside the RIS records the source JSONL SHA-256, RIS SHA-256, record count and file size.

## Figure set

Workflow 09 publishes 15 final manuscript figures in both PNG and PDF formats.

| Figure | Content | Authoritative implementation |
|---:|---|---|
| 1 | Review/process flow | `visualisations/07_flow_diagram.R` |
| 2 | Database contribution and overlap before/after screening | `scripts/reporting/plot_citesource_database_contribution.R` |
| 3 | Publication year × focal species | `visualisations/01_records_by_publication_year.R` |
| 4 | Publication year × high-level topic | `visualisations/05_records_by_publication_year_high_level_topic.R` |
| 5 | Global country choropleth | `visualisations/03_choropleth_records_by_country.R` |
| 6 | Top countries × focal species | `visualisations/02_records_by_country.R` |
| 7 | High-level topic frequency × focal species | `visualisations/04_topic_hierarchy.R` |
| 8 | Production topic hierarchy | `visualisations/04_topic_hierarchy.R` |
| 9 | Environment topic hierarchy | `visualisations/04_topic_hierarchy.R` |
| 10 | Methods topic hierarchy | `visualisations/04_topic_hierarchy.R` |
| 11 | Industry and governance topic hierarchy | `visualisations/04_topic_hierarchy.R` |
| 12 | Product topic hierarchy | `visualisations/04_topic_hierarchy.R` |
| 13 | People and society topic hierarchy | `visualisations/04_topic_hierarchy.R` |
| 14 | Inputs and resources topic hierarchy | `visualisations/04_topic_hierarchy.R` |
| 15 | Topic coverage in the supplied umbrella review | `visualisations/08_umbrella_review_figure.R` |

The previously explored rapidly-emerging-topics figure is not part of the final Workflow 09 manuscript package because its analytical definition was not retained.

## Manuscript outputs

The permanent source documents are:

- `long_form_methods.Rmd`;
- `long_form_results.Rmd`; and
- `references.bib`.

The Workflow 09 production run renders both Methods and Results to:

- Markdown (`.md`);
- HTML (`.html`);
- Word (`.docx`); and
- PDF (`.pdf`).

Results values are calculated during rendering from the restored authoritative data rather than copied from a static table. This includes evidence-base size, publication-year counts, species frequencies, geography coverage, topic frequencies and flow counts.

The generated files are committed back to the same feature branch with `[skip ci]` so the repository itself contains the final publication snapshot rather than relying on expiring Actions artefacts.

## Validation rules

A publication package is accepted only when all of the following hold:

1. the restored Workflow 08 JSONL SHA-256 matches the registered authoritative pointer;
2. the RIS source checksum matches that same JSONL;
3. the RIS record count exactly matches the current Workflow 08 pointer;
4. the review-flow data reconcile exactly to the final included population and upstream exclusion counts;
5. all 15 PNG figures exist;
6. the corresponding PDF figures exist;
7. Methods and Results each exist in Rmd source plus Markdown, HTML, Word and PDF forms; and
8. all permanent outputs are staged under `docs/reporting/workflow_09/`.

No model calls, screening decisions or annotation decisions are performed in Workflow 09.

## Provenance and reproducibility

The Workflow 09 package preserves:

- the exact Workflow 08 pointer used;
- source JSONL SHA-256;
- RIS SHA-256 and record count;
- flow-count JSON;
- current version-controlled plotting code;
- rendered figure files;
- current Methods and Results source;
- rendered manuscript outputs; and
- the Git commit and Actions run that produced the package.

The plotting-code snapshot under `figure_code/` is included for publication reproducibility. The canonical source scripts elsewhere in the repository remain the maintained implementations.

## Storage model

### Permanent repository outputs

GitHub stores:

- all final manuscript figures in PNG and PDF;
- a snapshot of all R code needed to regenerate those figures;
- Methods and Results Rmd sources;
- rendered Methods and Results in Markdown, HTML, Word and PDF;
- the complete-record RIS export and manifest;
- final flow counts; and
- this Workflow 09 methodological record.

### GitHub Actions artefact

Each production run also uploads the complete `docs/reporting/workflow_09/` publication package as a 90-day Actions artefact for convenient run-level inspection.

### Authoritative analytical archive

The Workflow 08 layer remains the authoritative source of the canonical JSONL and exclusions. Workflow 09 restores that state from the latest registered restricted Zenodo publication and does not claim that its RIS or manuscript files replace the canonical archive.

## Downstream handoff

Workflow 09 is the reporting endpoint for the manuscript and static publication package. Workflow 10 may consume the same final canonical data to build the interactive dashboard, but the dashboard is not authoritative for manuscript counts.

Future living updates should rerun Workflow 09 after a new validated Workflow 08 final state is published. The production controller selects the latest registered Workflow 08 pointer and validates its checksum, record count and lossless handoff contract before regenerating the publication package.

## Methods text for research reporting

> **Workflow 09: reporting and publication outputs.** The final included canonical evidence base was restored from the checksum-registered Workflow 08 archive and combined with preserved upstream provenance where required for reporting. All manuscript counts and figures were regenerated programmatically in R from these authoritative inputs. A complete-record RIS library was produced as a lightweight bibliographic representation of the canonical corpus, while the nested JSONL remained the authoritative provenance-preserving data structure. The Methods and Results manuscripts were maintained as version-controlled R Markdown sources and rendered reproducibly to Markdown, HTML, Word and PDF. Final figures, plotting code, manuscript outputs, the RIS library and machine-readable flow counts were committed as a versioned publication package.

## Reporting status

Workflow 09 is complete when the publication workflow passes all validation checks and commits the generated package to `workflow01-final-architecture`. The final successful run and generated checksums are recorded in the repository publication package and branch history.
