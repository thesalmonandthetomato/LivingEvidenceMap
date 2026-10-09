# Minimal production reconstruction: dependency manifest

Source: `workflow01-final-architecture` at `6eca21aea0b90b5c870bc25ff171ed647067de50`. Shiny source: `LivingEvidenceMapAdjudication/main` (read-only).

## Status

Initial manifest covers production workflow entry points, confirmed Shiny queue publication entry points, coding configurations, core ontologies and dictionaries, and likely R modules. These are **candidates**, not a verified complete transitive dependency graph. No workflow has been executed.

## Safety

Do not run workflows from this branch until hardcoded production refs, Zenodo publication endpoints, GitHub dispatch targets and Shiny shared-state writes are isolated.

## Remaining work

- Trace workflow `run:` and `uses:` paths through sourced R modules and scripts.
- Trace Shiny app references in both directions, including dynamic paths and status files.
- Distinguish read-only Zenodo pointers from mutable GitHub/Sheets state.
- Select minimal scripts, state registries, reporting templates, visualisation source and dashboard publication assets.
- Validate structure and R/YAML syntax without publishing.

## Newly added candidate files

- `.github/workflows/report_workflow09_topic_figures.yml`
- `.github/workflows/shiny-adjudication-publish-w01-queue.yml`
- `.github/workflows/shiny-adjudication-publish-w02-queue.yml`
- `.github/workflows/shiny-adjudication-publish-w04-validation.yml`
- `.github/workflows/workflow_00_manual_ris_zenodo.yml`
- `R/deduplication.R`
- `R/geography_detect.R`
- `R/geography_grounding.R`
- `R/geography_primary_country.R`
- `R/llm_adjudication.R`
- `R/llm_screening.R`
- `R/publication_status.R`
- `R/read_corpus.R`
- `R/relevance_screening.R`
- `R/run_topic_three_luna_production.R`
- `R/run_update_topic_classification.R`
- `R/species_annotation.R`
- `R/species_assign.R`
- `R/species_detect.R`
- `R/species_filter.R`
- `R/topic_classification.R`
- `R/workflow_10_build_search_trial.R`
- `R/workflow_10_dashboard_from_canonical_jsonl.R`
- `R/workflow_10_make_public_dashboard.R`
- `R/workflow_10_make_standalone_preview.R`
- `config/geography_scoring_dictionary.csv`
- `config/global_country_gazetteer_v3.csv`
- `config/iso3_numeric_map.json`
- `config/openai_model_pricing.json`
- `config/project.yml`
- `config/workflow00_ris_registry.schema.json`
- `config/workflow01_explicit_cluster_splits.json`
- `config/workflow01_identifier_never_auto_resolve.csv`
- `config/workflow01_source_catalogue.json`
- `config/workflow05_geography_semantic_prompt.txt`
- `config/workflow05_geography_semantic_prompt_v1.txt`
- `config/workflow05_luna_independent_audit_prompt.txt`
- `user_input/workflow00_ris_registry.example.json`
- `user_input/workflow04_screening_config.json`
- `user_input/workflow04_screening_highlight_terms.csv`
- `user_input/workflow04_screening_prompt.txt`
- `user_input/workflow05_species_dictionary_reference.csv`
- `user_input/workflow06_geography_domain_config.json`
- `user_input/workflow06_geography_semantic_prompt.txt`
- `user_input/workflow07_topic_ontology.csv`
- `user_input/workflow07_topic_system_prompt.txt`
- `user_input/workflow07_zero_topic_rescreen_prompt.txt`
- `user_input/workflow08_human_review_config.json`
