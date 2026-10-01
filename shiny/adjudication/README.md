# LivingEvidenceMap adjudication Shiny prototype

This is an isolated prototype for Workflow 01 duplicate adjudication.

It does **not** modify Workflow 01 and does **not** write to canonical data.

## Current scope

- reads the existing W01 duplicate-adjudication case schema;
- displays the two bibliographic records side by side;
- displays deterministic matching evidence;
- accepts `duplicate`, `not_duplicate`, or `uncertain`;
- requires a rationale;
- stores active prototype decisions locally in JSONL;
- records the queue SHA-256 with each decision;
- provides an exporter compatible with the existing W01 human-decision JSONL contract.

The default bundled fixture contains two real W01 adjudication cases copied from the locked 730-case recovery artefact from run `36049567027`. Its provenance is recorded in `fixtures/w01_real_sample_2.provenance.json`. It is for UI/contract development only and must not be used to resume that historical run.

## Run locally

From `shiny/adjudication`:

```r
install.packages(c("shiny","bslib","jsonlite","digest"))
shiny::runApp()
```

Optional environment variables:

- `LEM_W01_QUEUE`: path to a real locked W01 queue JSONL
- `LEM_W01_DECISIONS`: path for the local decision store
- `LEM_REVIEWER`: reviewer identifier

## Architecture

The local storage module is temporary. It will be replaced by a Google Sheets storage adapter after the W01 UI and round-trip contract have been validated.

No shinyapps.io or Google credentials are currently required.


## Google Sheets backend

The app now supports two storage modes:

- `local` (default): development JSONL store.
- `google_sheets`: append-only Google Sheets decision log.

Set `LEM_STORAGE_BACKEND=google_sheets` plus the variables documented in `GOOGLE_SHEETS_SETUP.md`.

The Sheets backend appends a new immutable row for each decision or revision and verifies that row before the UI treats the save as successful. Existing W01 workflow files remain unchanged.
