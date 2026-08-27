# Workflow 03: Duplicate adjudication

## Purpose

Resolve residual duplicate candidates emitted by Workflow 02 without allowing an LLM to silently overwrite deterministic evidence.

## Input

JSONL candidate records from Workflow 02. Each candidate identifies the incoming record, the matched historical record, the deterministic matching basis, and similarity/evidence fields.

## Decision contract

The adjudicator may return exactly one of:

- `duplicate`
- `not_duplicate`
- `uncertain`

Each decision must include a confidence value from 0 to 1 and a non-empty rationale.

## Processing states

`candidate` -> `adjudication_pending` -> `adjudicated`

An `uncertain` model result or technical model failure transitions to:

`human_review_required`

No record in `human_review_required` may be promoted as either duplicate or new until a human decision is recorded.

## Provenance

Every adjudication retains:

- candidate identifier;
- incoming and historical record identifiers;
- deterministic duplicate basis;
- deterministic similarity/evidence;
- model name and model version where applicable;
- model request/response provenance where retained by the pipeline;
- decision;
- confidence;
- rationale;
- timestamp;
- execution/run identifier;
- technical failure state and message, where applicable.

## Human review boundary

Human review is a separate stage from model adjudication. The review queue contains only unresolved or technically failed cases. The queue must be restartable and must retain the original candidate and adjudication artefacts.

The eventual notification workflow will email `nealhaddaway@gmail.com` with a link to the review interface and allow cases to be considered one-by-one. Human decisions will be appended to the audit trail rather than replacing the model response.

## Safety rules

- Do not use topical similarity as evidence of duplicate identity.
- Do not treat DOI as sufficient evidence by itself.
- Do not discard the original rich Lens record.
- Do not overwrite prior model or human decisions.
- Do not silently convert technical failures into substantive `uncertain` decisions.
