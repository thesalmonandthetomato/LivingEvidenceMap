# Shiny adjudication interface handover

## Status

Branch: `shiny-adjudication-interface`

Base branch: `workflow01-final-architecture`

Current state: planning only. No existing workflow, script, configuration, or production file has been modified on this branch.

## Objective

Build a reusable, topic-agnostic human adjudication interface for LivingEvidenceMap using an R Shiny app hosted on shinyapps.io, with Google Sheets used only as a persistent append-only decision store.

The app should support adjudications arising from W01, W02 and later downstream workflows such as W04-W08. Existing workflows should remain unchanged wherever possible.

## Agreed architecture

The existing workflows remain authoritative for producing adjudication cases and consuming adjudicated results.

High-level flow:

1. Existing workflow produces its normal adjudication output.
2. A new generic adapter/publish process transforms those cases into a frozen adjudication batch for the Shiny app without changing the originating workflow.
3. The Shiny app presents purpose-built review screens.
4. Each decision is written immediately to a dedicated Google Sheet using a service account.
5. The decision log is append-only. Revisions create a new row that supersedes the earlier decision rather than editing history.
6. A new generic GitHub-side sync/receive process reads completed decisions from the Sheet, validates them, and recreates the exact adjudication file format already expected by the relevant existing workflow.
7. Existing workflow continues as before.

The intended compatibility pattern is:

`existing workflow -> adapter -> Shiny -> Google Sheets -> adapter -> existing workflow`

The Shiny app must not modify canonical JSONL directly.

## Security model

- The Shiny app must not receive GitHub credentials or repository write access.
- shinyapps.io authentication should restrict access to authorised reviewers.
- A dedicated Google service account should be used by the Shiny app and shared only with the dedicated adjudication spreadsheet.
- GitHub Actions should use a separate credential stored in GitHub Secrets to read the adjudication spreadsheet.
- Prefer least privilege. The Shiny identity needs only the access necessary to read cases if stored there and append decisions. The GitHub identity should ideally be read-only for the decision store.
- No Google credentials may be committed to the repository.
- No secrets may be embedded in R files, YAML files, logs, artefacts, or documentation.

## Persistence and disconnect behaviour

A decision is not treated as complete until the persistent Google Sheet write has been confirmed.

Required sequence:

1. User chooses a decision.
2. App generates a unique decision ID.
3. App writes the decision.
4. App confirms the write succeeded.
5. Only then does the UI advance to the next case.

If the connection fails, the app must remain on the current case or reconstruct state from the decision log after reconnection.

Repeated submissions must be safe. Decision IDs should make saves idempotent or otherwise prevent duplicate accidental decisions.

The app must not rely on shinyapps.io local filesystem storage for persistent adjudication state.

## Decision-log model

Google Sheets is not the source of truth for the scientific records and is not the primary adjudication interface. It is a lightweight persistent audit log.

Suggested decision fields:

- decision_id
- batch_id
- workflow
- case_type
- case_id
- reviewer_id
- decision
- decision_value
- timestamp
- source_hash
- supersedes_decision_id
- comment

The log should be append-only.

A correction creates a new decision linked through `supersedes_decision_id`.

## Frozen batches

Adjudication inputs should be frozen and versioned.

Each batch should include at least:

- batch_id
- originating workflow
- case type
- creation timestamp
- source file/hash or canonical-input hash
- cases
- allowed decision vocabulary

Decisions must reference the batch and source hash.

When receiving decisions back into GitHub, the adapter must reject stale or mismatched batches rather than silently applying adjudications to changed data.

## UI goals

The app should be visually clean and designed around each adjudication task rather than reproducing spreadsheets.

Examples:

### Duplicate adjudication

Display two records side by side, including:

- full title
- authors
- year
- journal
- DOI and other identifiers
- abstract
- source/database provenance
- similarity/matching signals
- highlighted agreements and conflicts

Primary decisions might be:

- SAME RECORD
- DIFFERENT RECORDS
- UNSURE

For duplicate clusters, support cluster-level review rather than forcing pairwise decisions when the workflow produces a cluster.

### W01 metadata repair/enrichment

Show:

- source record
- candidate repaired/enriched record or records
- field-by-field comparison
- title/author/year/journal/identifier evidence
- source provenance
- match scores or deterministic evidence

Allow selection of the correct candidate, neither, or unsure.

### Species/geography/topic review

Show the complete title and abstract.

Highlight relevant terms using the same project inputs/ontologies already used by the coding workflows where possible.

Display:

- deterministic cues
- model-derived classifications
- model agreement/stars where relevant
- current candidate classification
- controlled options for correction
- NONE/uncoded where permitted

The app must not invent evidence or alter workflow coding logic.

## Topic-agnostic design

The Shiny app should be reusable across evidence-map projects.

Avoid hard-coding salmon-specific terminology into the application logic.

Where possible, render fields and controlled vocabularies from configuration or batch metadata, for example:

- species ontology
- geography values
- topic ontology
- intervention/exposure/outcome ontologies in future projects

Specialised UI modules may exist for case types such as duplicate comparison, candidate-match selection and multi-select coding, but the scientific vocabulary should come from project inputs.

## Existing-workflow constraint

This is a hard requirement:

**Do not modify existing W01, W02, W04, W05, W06, W07 or W08 workflow functionality merely to support the Shiny app.**

Prefer new sidecar/adaptor components.

Potential new GitHub Actions may be added for:

- publishing/exporting adjudication cases to the Shiny-facing format
- receiving/synchronising adjudication decisions from Google Sheets

These should sit alongside existing workflows and translate between current workflow file formats and the generic Shiny schema.

Before changing any existing workflow file, stop and obtain explicit permission.

## Minimal-repository-change rule

Repository changes should be limited to what is necessary for:

- the Shiny app
- generic adjudication adapters
- Google Sheets interfacing
- documentation/tests directly supporting these components

Do not refactor unrelated code.

Do not touch `main`.

Use R for repository workflow/application code unless there is a compelling reason otherwise.

Prioritise data integrity, provenance, reproducibility and auditable transformations over convenience.

## Validation requirements

Before any decisions are converted back into existing workflow inputs, validate at minimum:

- recognised workflow
- recognised batch
- recognised case ID
- source hash matches
- allowed decision vocabulary
- referenced record IDs exist
- required fields are complete
- reviewer identity is valid
- supersession chain is valid
- no malformed or ambiguous values are silently accepted

A validation failure must fail closed and leave the existing workflow inputs unchanged.

## Auditability

The system should preserve enough information to reconstruct:

- exactly what case the reviewer saw
- which frozen batch it belonged to
- what decision was made
- who made it
- when it was made
- whether it superseded an earlier decision
- what source version/hash the decision applied to

Spreadsheet/CSV/XLSX exports may continue to be produced for archival or human-readable audit purposes even if the Shiny app becomes the normal adjudication interface.

## Next step

Do not begin by editing W01/W02/W08.

First audit the current adjudication outputs and inputs of W01 and W02, and then W08, to establish the exact existing file contracts that the adapters must preserve.

For each workflow identify:

- where adjudication cases are written
- schema/columns
- whether cases are pairwise or clustered
- what file is later read back
- allowed decision values
- how completion is detected
- how decisions alter canonical or intermediate outputs

Then propose the smallest generic Shiny-case schema and adapter design that can reproduce those contracts exactly.

Make no functional changes until that audit has been reviewed.

## Prompt for a new ChatGPT conversation

> We are continuing work on `thesalmonandthetomato/LivingEvidenceMap` on branch `shiny-adjudication-interface`, branched from `workflow01-final-architecture`. Do not touch `main`.
>
> Read `docs/shiny_adjudication_handover.md` first and treat it as the controlling design note.
>
> We are building a reusable, topic-agnostic human adjudication system using an R Shiny app hosted on shinyapps.io. Google Sheets is to be used only as a persistent append-only decision store behind the app, not as the user interface or scientific source of truth.
>
> Existing workflows must remain unchanged wherever possible. In particular, do not modify W01, W02, W04-W08 functionality merely to support Shiny. Prefer new sidecar adapters and, if needed, new GitHub Actions that translate the workflows' existing adjudication outputs into a generic Shiny batch and translate completed Shiny decisions back into the exact files the workflows already expect. Before making any change to an existing workflow file, ask for explicit permission.
>
> Security requirements: Shiny must have no GitHub credentials or repository write access. Use a dedicated Google service account limited to the adjudication spreadsheet; keep all credentials out of the repository. GitHub should read decisions using a separate secret/credential. Decisions must be append-only and auditable. A decision is complete only after the persistent write succeeds. Disconnects, retries and duplicate submissions must not silently lose or duplicate decisions.
>
> Frozen adjudication batches must be versioned and hashed so that stale decisions cannot be applied to changed source data. The receiving adapter must fail closed on invalid or mismatched cases.
>
> The intended UI includes specialised views for W01 metadata-repair adjudication, W02 duplicate/cluster adjudication, and downstream species/geography/topic review. Titles and abstracts should be shown in full, with relevant deterministic/ontology cues highlighted where useful.
>
> Repository changes should be minimal and limited to the Shiny app, adapters, Google Sheets interface, directly related tests and documentation. Use R for repo code/workflows unless there is a compelling reason otherwise. Preserve provenance and reproducibility.
>
> **Start by auditing the existing W01 and W02 adjudication contracts, then W08: identify current output files, input files, schemas, allowed decisions, completion logic and how decisions are applied. Make no functional changes during this audit. Then propose the minimum adapter/Shiny schema that can reproduce those existing contracts without changing the workflows.**
