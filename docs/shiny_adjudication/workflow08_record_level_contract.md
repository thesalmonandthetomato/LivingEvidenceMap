# Workflow 08 Shiny adjudication contract

## Scope

Workflow 08 human review is record-level. A record appears only once in the active Shiny queue and contains an `issues` array with every **current human-review issue** for that record.

Current production does not send W05 species-`NONE` records to Shiny: those records are deterministically excluded before queue construction. Historical queues may contain species issues and remain readable for reproducibility.

## Queue schema

Schema:

`living-evidence-map-workflow08-shiny-record-case-v1`

Each record-level case contains:

- `record_id`;
- bibliographic display fields;
- `record_case_sha256`;
- `issues`;
- queue/batch provenance; and
- the species/topic option metadata required by the interface.

Each issue contains:

- `review_key`;
- `source_workflow`;
- `issue_type`;
- `issue_state_sha256`;
- `allowed_human_outcomes`;
- automated evidence/value; and
- issue-specific provenance.

The queue SHA-256 is calculated from the exact record-level JSONL bytes.

## Current production issue types

Current W08 production can generate:

- `geography_unresolved`;
- `geography_evidence_unvalidated`;
- `geography_model_failure`;
- `topic_coding_review`; and
- `zero_topic_eligibility_uncertain`.

Historical issue types remain supported by the backend finaliser where required to reproduce an older run, including:

- `species_none`;
- `topic_extreme_disagreement`; and
- `ontology_pathology`.

`topic_extreme_disagreement` is not a current production route. Mean pairwise Jaccard is descriptive QC only.

## Human-review rule

All current issues for a record are displayed together. A record is complete only when every issue in its `issues` array has a valid decision.

### Geography

For `geography_unresolved` and `geography_evidence_unvalidated`:

- `accept_model`;
- `override_country_set`;
- `assign_none`;
- `exclude_record`.

For `geography_model_failure`:

- `assign_country_set`;
- `assign_none`;
- `exclude_record`.

### Topics

For `topic_coding_review`:

- `accept_retained_topics`;
- `replace_topic_set`;
- `no_code`;
- `exclude_record`.

For `zero_topic_eligibility_uncertain`:

- `assign_topic_set`;
- `include_uncoded`;
- `exclude_record`.

## Decision schema

Schema:

`living-evidence-map-workflow08-shiny-record-decision-v1`

A saved record-level decision contains:

- `record_id`;
- `queue_sha256`;
- `record_case_sha256`;
- `issue_decisions_json`;
- reviewer; and
- resolution timestamp.

Each expanded issue decision contains the stable `review_key`, exact `issue_state_sha256`, decision, final value where applicable and queue provenance.

## Stale-session protection

Before saving a W08 record, the Shiny app reloads the live queue metadata and compares the live queue SHA-256 with the session SHA-256.

If they differ:

1. the stale save is refused;
2. the active batch is reloaded from Sheets; and
3. the reviewer must inspect the current record state before saving.

Opening W08 also refreshes the active queue rather than relying on the state loaded at login.

## Completion and resume

When no unresolved records remain:

1. Shiny records `review_complete` for the exact batch/SHA;
2. the W08 resume request is dispatched;
3. if direct GitHub `workflow_dispatch` is unavailable because the workflow is not on the repository default branch, Shiny writes a branch-safe resume marker under `docs/shiny_adjudication/w08_resume_requests/`;
4. the listener calls the reusable W08 resume workflow;
5. the backend exports decisions for the exact active queue;
6. compatible cumulative decisions are combined with the current batch;
7. finalisation requires exact coverage of every current `review_key + issue_state_sha256`; and
8. the batch is marked `consumed` only after the final W08 canonical state is archived and registered.

## Dashboard status

The Shiny home screen displays the current pipeline status separately from adjudication queues. The backend appends current-run state to the `pipeline_run_status` sheet after each accepted workflow stage.

The app polls that sheet every 30 seconds. Therefore the dashboard requires no application redeploy when a workflow completes; it updates after the backend status row is written.

Current production workflows W00-W08 update this status explicitly within their accepted completion paths rather than relying on a secondary workflow being triggered by an Actions `GITHUB_TOKEN` push.

## Permanent adjudication cards

The Shiny home screen permanently displays the principal verification stages, including:

- Deduplication — Workflow 01;
- Enrichment — Workflow 02;
- Screening — Workflow 04; and
- Annotation — Workflow 08.

Cards remain visible with zero outstanding cases when no review batch is active.

## Provenance principle

Automated W05-W07 outputs remain immutable. Workflow 08 human decisions are an auditable overlay. Shiny never edits the canonical JSONL directly.
