# Workflow 09 figure inventory

Workflow 09 publishes 15 final manuscript figures in both PNG and PDF under `docs/reporting/workflow_09/figures/`. The corresponding R source snapshot is stored under `docs/reporting/workflow_09/figure_code/`.

| Manuscript figure | Purpose | Permanent figure file stem | R implementation |
|---:|---|---|---|
| 1 | Review/process flow | `figure_01_flow_diagram` | `visualisations/07_flow_diagram.R` |
| 2 | Database contribution and exact source overlap for the deduplicated and definitive final included corpora | `figure_02_database_contribution` | `scripts/reporting/plot_citesource_database_contribution.R` |
| 3 | Records by publication year and focal species | `figure_03_publication_year_species` | `visualisations/01_records_by_publication_year.R` |
| 4 | High-level topic assignments by publication year | `figure_04_publication_year_topics` | `visualisations/05_records_by_publication_year_high_level_topic.R` |
| 5 | Global distribution of included records by substantive study country | `figure_05_country_choropleth` | `visualisations/03_choropleth_records_by_country.R` |
| 6 | Top countries by focal species | `figure_06_country_species` | `visualisations/02_records_by_country.R` |
| 7 | High-level topics by focal species | `figure_07_top_level_topics` | `visualisations/04_topic_hierarchy.R` |
| 8 | Production topic hierarchy | `figure_08_production` | `visualisations/04_topic_hierarchy.R` |
| 9 | Environment topic hierarchy | `figure_09_environment` | `visualisations/04_topic_hierarchy.R` |
| 10 | Methods topic hierarchy | `figure_10_methods` | `visualisations/04_topic_hierarchy.R` |
| 11 | Industry and governance topic hierarchy | `figure_11_industry_and_governance` | `visualisations/04_topic_hierarchy.R` |
| 12 | Product topic hierarchy | `figure_12_product` | `visualisations/04_topic_hierarchy.R` |
| 13 | People and society topic hierarchy | `figure_13_people_and_society` | `visualisations/04_topic_hierarchy.R` |
| 14 | Inputs and resources topic hierarchy | `figure_14_inputs_and_resources` | `visualisations/04_topic_hierarchy.R` |
| 15 | Topic coverage in the supplied umbrella review | `figure_15_umbrella_review` | `visualisations/08_umbrella_review_figure.R` |

## Final design rules

Figures 3 and 4 use the same publication-year axis layout, aspect ratio, typography, horizontal reference-grid treatment and right-hand legend placement.

Figures 7-14 use a common horizontal-bar design with the x-axis label **Number of records**, consistent typography, grid treatment and margins. Figure heights for theme-specific plots scale with the number of topic rows to avoid vertically stretching small panels such as Methods.

Figures 7-14 contain no internal titles, subtitles or below-plot explanatory captions. Explanatory wording belongs in manuscript figure captions.

The rapidly-emerging-topics figure explored during development is not part of the final figure set because its analytical definition was not retained.

## Data source

All analytical figures use the final included-only Workflow 08 canonical JSONL through `visualisations/canonical_figure_data.R`. Workflow 09 selects the latest registered Workflow 08 Zenodo pointer and verifies the canonical SHA-256 before publication.

Figures requiring upstream process/provenance data additionally restore the corresponding validated Workflow 01, Workflow 02 and Workflow 04 states. These are reporting inputs only and do not replace Workflow 08 final inclusion decisions.
