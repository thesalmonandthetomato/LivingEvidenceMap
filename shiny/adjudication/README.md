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

The bundled fixture is synthetic but schema-faithful. It is intentionally labelled with `prototype` IDs and must never be treated as scientific data.

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
