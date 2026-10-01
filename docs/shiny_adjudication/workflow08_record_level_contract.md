# Workflow 08 Shiny adjudication contract

## Purpose

Workflow 08 human review is record-level. A record may require species, geography and topic verification simultaneously, and must appear only once in the Shiny review queue.

The existing dynamic Workflow 08 intake already satisfies the queue-side part of this design: each JSONL row is one unique `record_id` with an `issues` array containing every current W05-W07 issue for that record.

## Queue contract

Schema: `living-evidence-map-workflow08-shiny-record-case-v1`

Each record-level case contains:

- `record_id`
- `record_sequence`
- `title`
- `abstract`
- `issues`

Each issue retains the existing Workflow 08 issue contract:

- `source_workflow`
- `issue_type`
- `automated_value`
- `allowed_human_outcomes`
- `issue_state_sha256`

Current issue types are:

- `species_none`
- `geography_unresolved`
- `geography_evidence_unvalidated`
- `topic_extreme_disagreement`
- `zero_topic_eligibility_uncertain`

The Shiny queue SHA-256 is the SHA-256 of the exact record-level JSONL bytes.

## Human-review rule

One review screen represents one record.

All issues for that record are displayed together. A record is complete only when every issue in its `issues` array has a valid human decision.

Resolved annotation components that are not current review issues may be shown read-only for context but must not require a decision.

## Persistent decision contract

Google Sheets stores one append-only record-level decision row per completed save/revision.

Schema: `living-evidence-map-workflow08-shiny-record-decision-v1`

Fields:

- `decision_id`
- `record_id`
- `queue_sha256`
- `record_case_sha256`
- `issue_decisions_json`
- `reviewer`
- `resolved_at_utc`
- `supersedes_decision_id`

`issue_decisions_json` contains one decision object for every issue in the record-level case. Each object must retain:

- `review_key` = `record_id::issue_type`
- `record_id`
- `issue_type`
- `issue_state_sha256`
- `decision`
- `final_value`
- `rationale`
- `reviewer`
- `resolved_at_utc`
- `queue_sha256`

A revision supersedes the previous record-level decision but does not delete it.

## Return adapter

The return adapter expands the latest record-level Shiny decisions back to the existing Workflow 08 issue-level decision ledger.

It must fail unless:

1. the queue SHA-256 matches exactly;
2. every current record-level case has at most one latest decision;
3. every issue in every completed record has exactly one issue decision;
4. `review_key`, `issue_type` and `issue_state_sha256` match the frozen queue;
5. each decision is one of that issue's `allowed_human_outcomes`;
6. all pending issues are resolved before Workflow 08 finalisation resumes.

The expanded ledger must remain compatible with `workflow_08_finalize_canonical_dynamic.R`. No changes to the scientific finalisation semantics are required.

## Dashboard semantics

The Shiny home screen permanently displays four verification stages:

- Deduplication — Workflow 01
- Enrichment — Workflow 02
- Screening — Workflow 04
- Annotation — Workflow 08

Each card is always visible and shows `0` when no records remain.

The Annotation count is the number of unique records requiring review, not the number of individual annotation issues. A record requiring species, geography and topic review therefore contributes one to the remaining count.

## Provenance

Automated W05-W07 outputs remain immutable. Workflow 08 human decisions are an auditable overlay. Shiny must never edit the canonical JSONL directly.
