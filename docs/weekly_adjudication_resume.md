# Weekly adjudication resume

A held weekly update can be resumed only after every queued human-review record has a structured adjudication.

Commit a JSON file such as `data/adjudications/weekly/2026-09-09.json`:

```json
{
  "issue_number": 9,
  "update_date": "2026-09-09",
  "decisions": [
    {
      "record_id": "007-888-105-974-856",
      "relevance": "retain",
      "reason": "Human adjudication rationale"
    },
    {
      "record_id": "112-732-189-061-768",
      "geography": ["CAN", "USA", "CHL"],
      "reason": "Human adjudication rationale"
    }
  ]
}
```

Supported decision fields are `relevance`, `geography`, `species`, and `topic`. `relevance` must be `retain` or `exclude`. Every queued record must appear exactly once. Unknown, duplicate, missing, or unresolved adjudications cause the resume workflow to fail before master promotion.

Run **Resume weekly update after adjudication** with:

- `update_date`: the held weekly update date
- `issue_number`: the GitHub human-review issue number
- `adjudication_path`: the committed JSON path

The workflow validates and applies the decisions, rebuilds the candidate master, promotes it only after validation, persists the held Lens checkpoint, closes the review issue, and commits the promoted master. The master-file push then triggers the existing dashboard build workflow.
