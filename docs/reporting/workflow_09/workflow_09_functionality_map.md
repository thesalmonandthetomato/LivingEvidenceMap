# Workflow 09: reporting, publication outputs and reference-library export

## Purpose

Workflow 09 is the final reporting and publication stage of the LivingEvidenceMap pipeline. It does not alter screening or annotation decisions. Instead, it restores the latest authoritative Workflow 08 included-only canonical dataset and the compact upstream provenance state needed for reporting, then produces a reproducible publication package consisting of:

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

Workflow 09 no longer reconstructs the full Workflow 01 state or restores the Workflow 02 cumulative patch merely for reporting. Instead, each accepted Workflow 00-08 stage writes a compact, version-controlled reporting summary to `docs/reporting/workflow_09_inputs/current/`. Workflow 01 and Workflow 08 additionally write small database-source/intersection snapshots. Workflow 09 validates those snapshots against the current registered run IDs and canonical checksums, then restores only the authoritative Workflow 08 final canonical state for analyses that genuinely require record-level final data.

## Components

| Component | Function |
|---|---|
| `.github/workflows/report_workflow09_figures.yml` | Production controller for compact-input validation, W08 restoration, RIS export, figure generation, manuscript rendering, validation and publication to the branch. |
| `docs/reporting/workflow_09_inputs/current/` | Clear current handoff directory containing one compact summary for each W00-W08 stage plus W01/W08 database-source snapshots and a checksum manifest. |
| `scripts/reporting/write_workflow09_stage_summary.R` | Writes the stage-owned compact W00-W08 reporting summary after an accepted workflow state. |
| `scripts/reporting/write_workflow09_source_snapshot.R` | Writes compact W01/W08 database source and exact-intersection snapshots from the canonical state while that large state is already present in the owning workflow. |
| `scripts/reporting/refresh_workflow09_input_manifest.R` | Rebuilds the manifest of current compact reporting inputs and their SHA-256 values. |
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

Workflow 09 restores the latest registered authoritative Workflow 08 Zenodo pointer from `docs/workflow08/zenodo/`. The restored canonical JSONL is accepted only when its SHA-256 and record count match that pointer. The current authoritative input is W08 run **37234697766**, Zenodo record **23145712** (DOI `10.5281/zenodo.23145712`), with **21,493 included records**. This makes reporting advance with a newly published Workflow 08 state rather than remaining pinned to a historical baseline.

The final Workflow 08 JSONL remains the authoritative representation because it preserves nested workflow provenance, screening state, species coding, geography coding, topic assignments and manifestation references.

### Compact upstream reporting handoff

Cross-workflow reporting inputs are maintained under:

`docs/reporting/workflow_09_inputs/current/`

The directory contains:

- `w00_summary.json` through `w08_summary.json`, one stage-owned compact summary per workflow;
- `w01_source_summary.csv` and `w01_source_intersections.csv`, describing source contribution and exact database intersections for the deduplicated W01 corpus;
- `w08_source_summary.csv` and `w08_source_intersections.csv`, describing the same source provenance for the definitive included W08 corpus;
- source-snapshot manifests carrying the corresponding canonical SHA-256 values; and
- `manifest.json`, which records the source run IDs, file sizes and SHA-256 values for the complete current handoff.

Each accepted workflow updates only its own summary after its authoritative state has been registered. W01 and W08 compute their source snapshots while their canonical JSONL is already available in that workflow, so W09 does not pay the cost of reconstructing those large states later.

Before rendering, W09 requires the W01-W08 summary run IDs to match `docs/current_run/current_run_status.json`, requires the W01 source snapshot checksum to match the registered W01 canonical checksum, and requires the W08 source snapshot checksum to match the authoritative final W08 canonical checksum. A stale or mixed reporting handoff therefore fails closed.

The compact inputs are also copied into each permanent W09 publication package under `docs/reporting/workflow_09/data/workflow_inputs/`, preserving the exact reporting handoff used for that publication snapshot.

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

Workflow 09 publishes 16 final manuscript figures in both PNG and PDF formats.

| Figure | Content | Authoritative implementation |
|---:|---|---|
| 1 | Review/process flow | `visualisations/07_flow_diagram.R` |
| 2 | Unique single-database contribution before and after final screening | `scripts/reporting/plot_citesource_database_contribution.R` |
| 3 | Exact multi-database overlap, excluding singleton contributions | `scripts/reporting/plot_citesource_database_contribution.R` |
| 4 | Publication year × focal species | `visualisations/01_records_by_publication_year.R` |
| 5 | Publication year × high-level topic | `visualisations/05_records_by_publication_year_high_level_topic.R` |
| 6 | Global country choropleth | `visualisations/03_choropleth_records_by_country.R` |
| 7 | Top countries × focal species | `visualisations/02_records_by_country.R` |
| 8 | High-level topic frequency × focal species | `visualisations/04_topic_hierarchy.R` |
| 9 | Production topic hierarchy | `visualisations/04_topic_hierarchy.R` |
| 10 | Environment topic hierarchy | `visualisations/04_topic_hierarchy.R` |
| 11 | Methods topic hierarchy | `visualisations/04_topic_hierarchy.R` |
| 12 | Industry and governance topic hierarchy | `visualisations/04_topic_hierarchy.R` |
| 13 | Product topic hierarchy | `visualisations/04_topic_hierarchy.R` |
| 14 | People and society topic hierarchy | `visualisations/04_topic_hierarchy.R` |
| 15 | Inputs and resources topic hierarchy | `visualisations/04_topic_hierarchy.R` |
| 16 | Topic coverage in the supplied umbrella review | `visualisations/08_umbrella_review_figure.R` |

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

Results values are calculated during rendering from the authoritative final W08 corpus and the checksum-validated compact workflow handoff rather than copied from a static table. Record-level final statistics use W08; cross-workflow flow/source counts use the compact W00-W08 summaries.

The generated files are committed back to the same feature branch with `[skip ci]` so the repository itself contains the final publication snapshot rather than relying on expiring Actions artefacts.

## Validation rules

A publication package is accepted only when all of the following hold:

1. the restored Workflow 08 JSONL SHA-256 matches the registered authoritative pointer;
2. the RIS source checksum matches that same JSONL;
3. the RIS record count exactly matches the current Workflow 08 pointer;
4. the compact W00-W08 stage summaries match the current-run workflow IDs;
5. the compact W01 and W08 source snapshots match their registered canonical SHA-256 values and record counts;
6. the review-flow data reconcile exactly to the final included population and upstream exclusion counts;
7. all 16 PNG figures exist;
8. the corresponding 16 PDF figures exist;
9. Methods and Results each exist in Rmd source plus Markdown, HTML, Word and PDF forms;
10. the exact compact workflow-input snapshot is staged with the publication package; and
11. all permanent outputs are staged under `docs/reporting/workflow_09/`.

No model calls, screening decisions or annotation decisions are performed in Workflow 09.

## Provenance and reproducibility

The Workflow 09 package preserves:

- the exact Workflow 08 pointer used;
- the W00-W08 compact reporting-input manifest and stage/source snapshots;
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
- a snapshot of the exact compact W00-W08 reporting inputs used;
- final flow counts; and
- this Workflow 09 methodological record.

### GitHub Actions artefact

Each production run also uploads the complete `docs/reporting/workflow_09/` publication package as a 90-day Actions artefact for convenient run-level inspection.

### Authoritative analytical archive

The Workflow 08 layer remains the authoritative source of the canonical JSONL and exclusions. Workflow 09 restores that state from the latest registered restricted Zenodo publication and does not claim that its RIS or manuscript files replace the canonical archive.

## Downstream handoff

Workflow 09 is the reporting endpoint for the manuscript and static publication package. Workflow 10 may consume the same final canonical data to build the interactive dashboard, but the dashboard is not authoritative for manuscript counts.

Future living updates automatically dispatch Workflow 09 after a new validated Workflow 08 final state has been published and its reporting handoff/status have been updated. Both the direct W08 production path and the post-Shiny W08 resume path call `report_workflow09_figures.yml` explicitly via workflow dispatch, avoiding reliance on recursive push events from `GITHUB_TOKEN`. Workflow 09 remains manually dispatchable for independent reproduction. The production controller selects the latest registered Workflow 08 pointer and validates its checksum, record count and lossless handoff contract before regenerating the publication package.

## Methods text for research reporting

> **Workflow 09: reporting and publication outputs.** Each accepted Workflow 00-08 state emitted a compact version-controlled reporting summary, with Workflow 01 and Workflow 08 additionally emitting source-provenance/intersection snapshots linked to their canonical checksums. Workflow 09 validated those small handoff files against the current registered workflow lineage and restored only the final Workflow 08 canonical evidence base for record-level analyses. All manuscript counts and figures were regenerated programmatically in R from these authoritative inputs. A complete-record RIS library was produced as a lightweight bibliographic representation of the canonical corpus, while the nested JSONL remained the authoritative provenance-preserving data structure. The Methods and Results manuscripts were maintained as version-controlled R Markdown sources and rendered reproducibly to Markdown, HTML, Word and PDF. Final figures, plotting code, manuscript outputs, the RIS library, compact workflow-input snapshot and machine-readable flow counts were committed as a versioned publication package.

## Reporting status

**COMPLETE and validated for the current release.** Production run **37268896083** successfully regenerated the complete Workflow 09 publication package from authoritative W08 run **37234697766** / Zenodo record **23145712** after the geography-code correction. All production validation steps passed, including authoritative W08 restoration, compact W00-W08 handoff validation, RIS export, all 16 figures, Methods and Results rendering, permanent package staging, package validation, branch commit and Actions artefact upload.

Workflow 09 remains reproducible independently through `.github/workflows/report_workflow09_figures.yml`, and is also explicitly dispatched by both successful published W08 completion paths.
