# Static evidence visualisations

Static figures are generated from the validated master evidence-map database using one R script per figure. The scripts are intentionally independent of the dashboard-building code so that manuscript figures can be regenerated directly from the current master dataset.

## Figures

- `01_records_by_publication_year.R` — number of records by publication year, stacked by species.
- `02_records_by_country.R` — number of records in the 20 most frequent study countries, stacked by species.

Each script writes both a 600-dpi PNG and a vector PDF to this directory.

## Source data

The scripts read `data/master/current/living_evidence_map_master.csv`. Country names for Figure 2 are resolved from `config/global_country_gazetteer_v3.csv` using the final primary study-country ISO3 code in the master database.

## Colour palette

Both figures use the project palette:

```r
color_palette(c(
  "#2c454a", "#577c84", "#a8bdbe", "#e2b8a2", "#ff9d78", "#e55634"
))
```

Where more than six species are present, the palette is extended using the same palette definition so that every observed species retains a distinct fill colour.

## Reproduction

Run each script from the repository root, for example:

```bash
Rscript visualisations/01_records_by_publication_year.R
Rscript visualisations/02_records_by_country.R
```
