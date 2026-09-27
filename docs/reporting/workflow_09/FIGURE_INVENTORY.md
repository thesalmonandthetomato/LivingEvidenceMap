# Workflow 09 figure inventory

The long-form Results report uses figures generated into `outputs/report/long_form/figures/`.

| Results figure | Purpose | R implementation | Status for final Workflow 09 |
|---|---|---|---|
| 1 | Database contribution and exact source overlap before/after relevance screening | `scripts/reporting/plot_citesource_database_contribution.R` | Existing validated implementation; redirect/copy final PNG/PDF into long-form output directory. |
| 2 | Review/process flow diagram | `visualisations/07_flow_diagram.R` | Added as a canonical JSONL/exclusions-CSV implementation following the current slide-template structure. Source-database counts remain TBC until current Workflow 00 source totals are restored. |
| 3 | Records by publication year and focal species | `visualisations/01_records_by_publication_year.R` | Migrated to the included-only W08 canonical JSONL. |
| 4 | High-level topic assignments by publication year | `visualisations/05_records_by_publication_year_high_level_topic.R` | Migrated to the included-only W08 canonical JSONL. |
| 5 | Records by country and focal species | `visualisations/02_records_by_country.R` | Migrated to the included-only W08 canonical JSONL. |
| 6 | Country choropleth | `visualisations/03_choropleth_records_by_country.R` | Migrated to the included-only W08 canonical JSONL. |
| 7 | High-level topics by focal species | `visualisations/04_topic_hierarchy.R` | Migrated to the included-only W08 canonical JSONL. |
| 8-14 | Theme-specific topic figures for Production, Environment, Methods, Industry and governance, Product, People and society, Inputs and resources | `visualisations/04_topic_hierarchy.R` | Migrated to the included-only W08 canonical JSONL. |
| 15 | Rapidly emerging topics relative to evidence-base growth | `visualisations/06_rapidly_emerging_topics.R`; `visualisations/06_rapidly_emerging_topics_annotated.R` now redirects to the canonical implementation | Migrated to the included-only W08 canonical JSONL. |
| 16 | Primary-study topic distribution versus systematic-review coverage | No current standalone script located | New reporting script required if retained in final manuscript. |

## Important input migration

The legacy static visualisation scripts previously read `data/master/current/living_evidence_map_master CORRECTED.csv`. That file represents the earlier dashboard/master architecture and is not the authoritative final Workflow 08 release. The figure scripts now read the final included-only canonical JSONL using `visualisations/canonical_figure_data.R`.

By default scripts look for `data/master/current/living_evidence_map_canonical_final.jsonl`, `outputs/workflow08_corrected/living_evidence_map_canonical_final.jsonl`, or `outputs/workflow08/living_evidence_map_canonical_final.jsonl`. They can also be pointed to a file with `--canonical-jsonl` or `CANONICAL_JSONL`.

## Flow diagram counts currently established

- Deduplicated canonical records: 32,292.
- Publication-status exclusions before relevance screening: 9.
- Records entering Workflow 04 relevance screening: 32,283.
- Workflow 04 retained: 19,407.
- Workflow 04 excluded: 12,876.
- Additional late exclusions attributed to Workflow 07 in final accounting: 122.
- Additional Workflow 08 human-review exclusions: 168.
- Final included evidence map: 19,117.
- Final included records without a retained topic code: 231.

The final diagram should show source-database retrieval counts separately once the current Workflow 00 source totals are restored, and should distinguish the 231 included-but-uncoded records from exclusions.
