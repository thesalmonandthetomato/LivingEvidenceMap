# AI assistant operating guidelines

These instructions apply to AI assistants, coding agents, and automated contributors working on the LivingEvidenceMap repository.

They are intended to protect data integrity, provenance, reproducibility, API budgets, and the auditability of the evidence-map pipeline.

## Priority order

Unless the user explicitly instructs otherwise, prioritise:

1. data integrity;
2. provenance and reproducibility;
3. methodological rigour and accuracy;
4. preservation of recoverable intermediate state;
5. minimising unnecessary external/API calls;
6. efficiency and speed.

Do not optimise for speed at the expense of correctness, auditability, or recoverability.

## Never fabricate

Never invent:

- files, branches, workflow behaviour, API responses, identifiers, record counts, artefacts, logs, citations, or repository state;
- dependencies or pipeline ordering that have not been verified;
- successful completion merely because a workflow is green.

If evidence is missing, inspect the repository, workflow logs, saved artefacts, or source API documentation. If something remains unknown, state that it is unknown.

## Artefact-first rule

Before making any external or potentially expensive call, check whether a valid artefact already exists.

If a complete artefact exists for the same:

- query/search;
- source/database;
- parameters;
- time/version;
- input state;

reuse that artefact instead of repeating the call.

Do not rerun an external database/API merely because downstream code, validation logic, formatting, or reconciliation has changed.

Only repeat an expensive external call when at least one of the following is true:

- the search/query itself changed;
- the source data must intentionally be refreshed;
- the prior artefact is incomplete, corrupt, expired, or demonstrably invalid;
- the user explicitly requests a fresh call.

When reusing an artefact, record exactly which run/artifact supplied the input.

## Artefact retention and checkpoints

For multi-step or expensive workflows:

- save raw source responses before transformation;
- checkpoint at sensible intervals;
- preserve partial progress on failure;
- upload diagnostic and intermediate artefacts even when the workflow fails;
- retain artefacts for at least a few days, and preferably longer for expensive or difficult-to-reproduce stages.

As a default for GitHub Actions, use retention long enough to support debugging and downstream reuse. Thirty days is appropriate for major API harvests unless there is a reason to choose otherwise.

For long harvests, checkpoint after each page, partition, batch, or similarly recoverable unit.

A workflow should be designed so that downstream validation or transformation can run from a saved artefact without repeating the upstream call.

## External API and cost control

Treat external calls as potentially costly even when current pricing is low.

Before calling an API:

1. inspect existing artefacts and prior successful runs;
2. check whether a smaller diagnostic sample can answer the immediate question;
3. determine whether the requested fields require the expensive endpoint/view;
4. use the largest safe page size allowed by the API;
5. avoid redundant calls for metadata already present in another preserved response.

Do not trade provenance for lower cost. Cost minimisation comes after integrity and completeness.

## Workflow minimisation

Prefer the smallest maintainable number of workflows.

Do not create a new GitHub Actions workflow for every minor diagnostic or code change when an existing workflow can be parameterised or reused safely.

Prefer:

- reusable scripts;
- reusable workflow jobs;
- explicit modes such as test, validation-only, resume, or full harvest;
- downloading an existing artefact for downstream tests.

Separate workflows are justified when isolation materially improves safety, permissions, provenance, or recoverability.

Avoid duplicate workflows that perform the same upstream API call.

## Validation-only changes must not re-harvest

If a complete source harvest has already succeeded but a later assertion, validator, adapter, formatter, or reconciliation step fails:

- keep the successful harvest;
- fix the downstream logic;
- rerun from the preserved artefact.

Do not re-query the source database solely to obtain another copy of identical input.

A green workflow is not the objective. A validated, provenance-preserved dataset is.

## Raw data preservation

Preserve raw source payloads losslessly whenever practical.

Do not overwrite raw fields with normalised values.

Derived, normalised, or canonical fields must remain distinguishable from source-native fields.

Where source metadata is ambiguous, preserve the original value and document the interpretation rather than silently coercing it.

## Identifiers and deduplication

Do not assume DOI equality or inequality alone establishes record identity.

Preserve source-native identifiers such as:

- Lens IDs;
- Scopus EIDs/Scopus IDs;
- OpenAlex IDs;
- AGRICOLA/Europe PMC source IDs;
- DOIs and other external identifiers.

Keep ingestion completeness separate from bibliographic deduplication.

Within a single harvest, repeated identifiers at pagination boundaries can indicate unstable paging and possible missing records. Investigate before simply dropping duplicates.

Cross-source or bibliographic duplicate resolution belongs in the designated deduplication/reconciliation stage and must preserve provenance for all contributing source records.

## Canonical data protection

Do not modify canonical JSON, authoritative masters, or promoted production outputs unless the current task explicitly permits it and the relevant upstream/downstream contract has been verified.

Diagnostic integrations should use sidecars, temporary artefacts, or test outputs rather than changing canonical schemas prematurely.

Never change identifier semantics merely to make a new source fit an existing schema.

## Search-method fidelity

Record the exact query, source, fields searched, date/time, API endpoint, parameters, view/result type, pagination method, and relevant API limitations.

Do not claim search equivalence when databases expose different searchable fields.

For example, title/abstract searching is not equivalent to title/abstract/keyword searching. Record such methodological differences explicitly.

## Failure handling

A failed workflow does not necessarily mean the data stage failed.

Inspect the failing step.

Distinguish between:

- source/API failure;
- incomplete harvest;
- pagination instability;
- transformation failure;
- validation failure;
- stale assertion/check;
- upload or deployment failure.

Do not discard a valid expensive artefact because a later cheap step failed.

If the workflow fails after preserving recoverable state, use that state for the next attempt wherever possible.

## Reproducibility and provenance

Every important derived dataset should be traceable back to:

- source;
- query/input;
- code version/commit;
- workflow/run;
- artefact;
- transformation;
- validation result.

Prefer machine-readable manifests and validation reports.

Do not rely on conversational memory as the only record of pipeline state.

## Repository changes

Before editing:

- inspect the current target file and branch;
- verify the active workflow and its dependencies;
- preserve unrelated behaviour;
- make the smallest change necessary;
- verify the exact path changed.

Do not infer current architecture from obsolete filenames, old branches, or prior conversation alone when repository state can be checked directly.

## Communication

Report results precisely.

Use terms such as PASS, FAIL, PARTIAL, or NOT VERIFIED only when supported by evidence.

When a run fails, identify the exact failing stage before proposing a fix.

When a run succeeds, verify the substantive outputs, not just the GitHub Actions conclusion.

Flag methodological compromises, source limitations, and assumptions explicitly.

## User instruction overrides

The user may explicitly choose speed, lower cost, reduced validation, or a manual shortcut.

When they do, follow that instruction while making the resulting trade-off clear.

Absent such an instruction, default to the rigorous, provenance-preserving, artefact-first approach above.
