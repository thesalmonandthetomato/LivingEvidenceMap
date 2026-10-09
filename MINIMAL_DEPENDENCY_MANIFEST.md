# Minimal repository: dependency closure and status

Source frozen at production commit `6eca21aea0b90b5c870bc25ff171ed647067de50`. Shiny source read-only: `thesalmonandthetomato/LivingEvidenceMapAdjudication/main`.

## Isolation

All 27 GitHub Actions YAML definitions remain under `.github/workflows-inert/`. None are under `.github/workflows/` on this branch. Original files retain their unsafe external write targets; **do not reactivate** until Zenodo publication, Git push, shared Google Sheets, dashboard publication and cross-repository dispatch are individually isolated.

## Static dependency inventory

- Inspected direct workflow scripts and nested literal paths in the 165 R/Python/shell source files present before this pass, including W00–W10 and Shiny queue/resume helpers.
- Added missing script helpers for W00 RIS, W01 restore, Shiny status and pipeline setup; added W00 manual source descriptors, W00/W02/W03 registry pointers, W08 geography corrections and dashboard/reporting input references.
- Shiny `R/github_dispatch.R` names and `app.R` state references have been inspected; Shiny's production repository and Google Sheets remain unchanged.
- Static patterns cannot establish closure for generated and dynamically computed files; no claim of validated run-readiness.

## Unresolved references (not silently substituted)

- `config/workflow06_geography_semantic_prompt_v2.txt`: referenced in W06 merge script; not in frozen source tree.
- `data/reference/topic_ontology_v3_6.csv`: referenced in W07 merge script; not in frozen source tree.
- `data/reference/topic_system_prompt_v3_6.txt`: referenced in W07 preparation script; not in frozen source tree.
- `docs/current_run/current_run_record_ids.txt`: referenced as runtime status output, not tracked in source; likely generated at runtime, verify later.
- Other generated W09 outputs (reports, figures, RIS manifests) must be generated during the relevant workflow and are not copied as old historical outputs.

## Stop point

Dependency copying only. **No structural validation, unit tests, Actions runs, API calls or functional testing carried out.**

## Legacy default paths resolved (2026-10-09)

The following fallback defaults were updated in `production-minimal` only to match the explicit inputs supplied by the current production workflows:

- `scripts/updater/workflow_06_merge_incremental.R`: default geography prompt now `user_input/workflow06_geography_semantic_prompt.txt`.
- `scripts/updater/workflow_07_merge_incremental_topics.R`: default ontology now `user_input/workflow07_topic_ontology.csv`.
- `scripts/updater/workflow_07_prepare_incremental.R`: default topic prompt now `user_input/workflow07_topic_system_prompt.txt`.

`docs/current_run/current_run_record_ids.txt` remains a runtime state path. These are targeted reference edits, not validation. Workflow YAML definitions remain inactive in `.github/workflows-inert/`.
