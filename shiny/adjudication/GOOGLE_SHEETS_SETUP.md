# Google Sheets decision backend

The Shiny app can use Google Sheets as an append-only decision log.

## Required environment variables

- `LEM_STORAGE_BACKEND=google_sheets`
- `LEM_GOOGLE_SHEET_ID=<spreadsheet ID>`
- `LEM_GOOGLE_DECISIONS_TAB=decisions` (optional; defaults to `decisions`)
- `LEM_GOOGLE_SERVICE_ACCOUNT_JSON=<service-account JSON path or JSON string>`

The service account JSON must never be committed to Git.

## Permissions

Share only the dedicated adjudication spreadsheet with the service-account email.

The app service account needs permission to append/read that spreadsheet. It should not have access to unrelated Drive content.

## Initialisation

From `shiny/adjudication`:

```r
install.packages(c("googlesheets4","jsonlite","digest"))
source("scripts/init_google_sheet.R")
```

The decision tab uses these columns:

- decision_id
- review_case_id
- decision
- rationale
- reviewer
- resolved_at_utc
- queue_sha256
- supersedes_decision_id

The log is append-only. A changed decision creates a new row linked to the previous active decision through `supersedes_decision_id`.

The app verifies the newly appended row before treating the case as saved.

For service-account authentication, `googlesheets4::gs4_auth(path=...)` accepts service-account JSON supplied as a path or JSON string. The app uses this non-interactive pattern rather than browser OAuth.
