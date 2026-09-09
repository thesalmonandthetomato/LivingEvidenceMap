# Weekly adjudications

Commit one JSON file per held weekly update, for example `2026-09-09.json`.

Required top-level fields:
- `issue_number`
- `update_date`
- `decisions`

Each item in `decisions` must contain `record_id` and one or more of `relevance`, `geography`, `species`, or `topic`. `relevance` must be `retain` or `exclude`. Every queued record must be adjudicated exactly once.

The resume workflow validates the adjudication against the held review artifact before any master promotion.
