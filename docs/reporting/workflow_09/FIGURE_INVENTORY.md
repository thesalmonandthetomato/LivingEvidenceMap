# Workflow 09 figure inventory

Workflow 09 publishes 16 final manuscript figures in both PNG and PDF under `docs/reporting/workflow_09/figures/`. The corresponding R source snapshot is stored under `docs/reporting/workflow_09/figure_code/`.

| Manuscript figure | Purpose | Permanent figure file stem | R implementation |
|---:|---|---|---|
| 1 | Review/process flow | `figure_01_flow_diagram` | `visualisations/07_flow_diagram.R` |
| 2 | Records contributed uniquely by each database, before and after final screening | `figure_02_database_unique_contribution` | `scripts/reporting/plot_citesource_database_contribution.R` |
| 3 | Exact multi-database overlap, excluding singleton source contributions | `figure_03_database_overlap` | `scripts/reporting/plot_citesource_database_contribution.R` |
| 4 | Records by publication year and focal species | `figure_04_publication_year_species` | `visualisations/01_records_by_publication_year.R` |
| 5 | High-level topic assignments by publication year | `figure_05_publication_year_topics` | `visualisations/05_records_by_publication_year_high_level_topic.R` |
| 6 | Global distribution of included records by substantive study country | `figure_06_country_choropleth` | `visualisations/03_choropleth_records_by_country.R` |
| 7 | Top countries by focal species | `figure_07_country_species` | `visualisations/02_records_by_country.R` |
| 8 | High-level topics by focal species | `figure_08_top_level_topics` | `visualisations/04_topic_hierarchy.R` |
| 9 | Production topic hierarchy | `figure_09_production` | `visualisations/04_topic_hierarchy.R` |
| 10 | Environment topic hierarchy | `figure_10_environment` | `visualisations/04_topic_hierarchy.R` |
| 11 | Methods topic hierarchy | `figure_11_methods` | `visualisations/04_topic_hierarchy.R` |
| 12 | Industry and governance topic hierarchy | `figure_12_industry_and_governance` | `visualisations/04_topic_hierarchy.R` |
| 13 | Product topic hierarchy | `figure_13_product` | `visualisations/04_topic_hierarchy.R` |
| 14 | People and society topic hierarchy | `figure_14_people_and_society` | `visualisations/04_topic_hierarchy.R` |
| 15 | Inputs and resources topic hierarchy | `figure_15_inputs_and_resources` | `visualisations/04_topic_hierarchy.R` |
| 16 | Topic coverage in the supplied umbrella review | `figure_16_umbrella_review` | `visualisations/08_umbrella_review_figure.R` |

## Final design rules

Figures 4 and 5 use the same publication-year axis layout, aspect ratio, typography, horizontal reference-grid treatment and right-hand legend placement.

Figures 8-15 use a common horizontal-bar design with the x-axis label **Number of records**, consistent typography, grid treatment and margins. Figure heights for theme-specific plots scale with the number of topic rows to avoid vertically stretching small panels such as Methods.

Figures 8-15 contain no internal titles, subtitles or below-plot explanatory captions. Explanatory wording belongs in manuscript figure captions.

The rapidly-emerging-topics figure explored during development is not part of the final figure set because its analytical definition was not retained.

## Data source

All analytical figures use the final included-only Workflow 08 canonical JSONL through `visualisations/canonical_figure_data.R`. Workflow 09 selects the latest registered Workflow 08 Zenodo pointer and verifies the canonical SHA-256 before publication.

Figures requiring upstream process/provenance data additionally restore the corresponding validated Workflow 01, Workflow 02 and Workflow 04 states. These are reporting inputs only and do not replace Workflow 08 final inclusion decisions.
