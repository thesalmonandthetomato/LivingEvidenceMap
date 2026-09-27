# Static evidence visualisations

Static manuscript figures are generated from the Workflow 08 **included-only canonical JSONL**. The legacy CSV master is no longer the authoritative source for manuscript figures.

## Figures

- `01_records_by_publication_year.R` — included records by publication year, stacked by species.
- `02_records_by_country.R` — included records in the 20 most frequent study countries, stacked by species.
- `03_choropleth_records_by_country.R` — global choropleth of included records by study country.
- `04_topic_hierarchy.R` — high-level topic overview and theme-specific topic hierarchy plots.
- `05_records_by_publication_year_high_level_topic.R` — included records by publication year, stacked by high-level topic.
- `06_rapidly_emerging_topics.R` — relative growth trajectories for rapidly emerging topics.
- `07_flow_diagram.R` — manuscript flow diagram based on final Workflow 08 accounting.

Each script writes a 600-dpi PNG and a vector PDF.

## Source data

By default, scripts look for one of the following included-only Workflow 08 canonical JSONL files:

1. `data/master/current/living_evidence_map_canonical_final.jsonl`
2. `outputs/workflow08_corrected/living_evidence_map_canonical_final.jsonl`
3. `outputs/workflow08/living_evidence_map_canonical_final.jsonl`

You can also pass the canonical file explicitly:

```bash
Rscript visualisations/01_records_by_publication_year.R --canonical-jsonl path/to/living_evidence_map_canonical_final.jsonl
```

or set:

```bash
export CANONICAL_JSONL=path/to/living_evidence_map_canonical_final.jsonl
```

The flow diagram optionally reads `workflow08_excluded_records.csv` via `--exclusions-csv` or `EXCLUSIONS_CSV`; if unavailable, it falls back to the validated W08 stage counts.

Country names are resolved from `config/global_country_gazetteer_v3.csv` where needed.

## Colour palette

The figures use the project palette:

```r
c("#2c454a", "#577c84", "#a8bdbe", "#e2b8a2", "#ff9d78", "#e55634")
```

## Reproduction

Run scripts from the repository root, for example:

```bash
Rscript visualisations/01_records_by_publication_year.R --canonical-jsonl outputs/workflow08_corrected/living_evidence_map_canonical_final.jsonl
Rscript visualisations/07_flow_diagram.R --canonical-jsonl outputs/workflow08_corrected/living_evidence_map_canonical_final.jsonl --exclusions-csv outputs/workflow08_corrected/workflow08_excluded_records.csv
```
