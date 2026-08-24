# Agent instructions for LivingEvidenceMap

## Scope

This repository maintains the salmon Living Evidence Map. When modifying the automated update infrastructure, use `REPO_MAP.yml` as the first dependency map and verify any change against the active GitHub Actions workflows.

## Evidence rule

Do not infer an undocumented dependency from filenames alone. If a dependency is not established by an active workflow, an executable script referenced by that workflow, the repository documentation, or prior project decisions recorded in the conversation, treat it as unknown and investigate it before changing it.

## Production update pathway

The primary automated update workflow is:

`.github/workflows/weekly_update_pipeline.yml`

Its active pathway is:

1. Harvest the Lens increment with `scripts/lens_weekly_harvest.py`.
2. Persist successful Lens search state.
3. Prepare the dated update input.
4. On zero records, stop cleanly and leave the master unchanged.
5. Otherwise run `scripts/run_lens_update.R` for deduplication, relevance screening, species and geography processing.
6. Reject technical LLM failures.
7. Run `R/run_update_topic_classification.R`.
8. Apply the human-review gate.
9. Build and validate a candidate master with `scripts/merge_master_update.py`.
10. Promote the validated candidate master to `data/master/current/living_evidence_map_master.csv` and archive the previous master.

The precise workflow is authoritative for ordering and conditional execution; do not replace it with a guessed dependency graph.

## Search-state rule

A successful Lens harvest is a successful search even when it returns zero records. The search checkpoint and search history therefore need to advance and persist after a successful harvest.

A failed harvest must not be treated as a successful search.

The current production retrieval uses Lens `created` with a seven-day overlap. Do not change this retrieval semantics to another Lens field without evidence from the API/workflow and an explicit project decision.

## Evidence/master rule

Do not modify the authoritative master directly from retrieval output.

New records must follow the existing update pathway and review/validation gates before promotion. The zero-record branch explicitly leaves the master unchanged.

The authoritative master is:

`data/master/current/living_evidence_map_master.csv`

Candidate masters are under:

`data/master/candidates/`

Archived masters are under:

`data/master/archive/`

## Dashboard rule

The dashboard has a separate build/deployment pathway:

- `.github/workflows/build-dashboard.yml`
- `.github/workflows/deploy-dashboard-pages.yml`

The dashboard data builder is:

`scripts/build_dashboard.py`

It reads the authoritative master and writes:

`docs/dashboard.json`

The approved presentation files are protected by the dashboard build workflow:

- `docs/index.html`
- `docs/topic-radial.js`

Do not assume that a persisted search checkpoint automatically changes a dashboard display. Verify which dashboard data source supplies the particular displayed field before changing it.

## Dashboard search-date caution

The current repository evidence shows that `scripts/build_dashboard.py` derives its `metrics.last_update` value from an update-like field in the master records. The Lens search checkpoint is stored separately in `state/lens_weekly_harvest.json`.

Therefore, if a user reports that the dashboard's "last search" date is stale, first trace the actual dashboard field and its source. Do not claim that updating the Lens checkpoint has updated the displayed dashboard date unless the dashboard build/deployment path has been verified.

## Workflow changes

When changing a workflow:

1. Read the current workflow from `main` immediately before editing.
2. Preserve existing conditions and gates unless the task explicitly changes them.
3. Keep search-state persistence separate from master promotion.
4. Test the exact workflow path that changed.
5. Verify both repository state and downstream generated/deployed output where the change affects a user-visible product.
6. If a diagnostic mode is introduced, ensure it cannot advance production checkpoints or promote the master.

## No fabrication

If the repository does not establish a file dependency, data source, or execution order, say so and investigate it. Do not invent placeholder dependencies and present them as production architecture.
