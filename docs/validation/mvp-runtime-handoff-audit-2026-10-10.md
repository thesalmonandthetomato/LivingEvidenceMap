# MVP runtime handoff audit, 10 October 2026

Branch: `production-minimal`. Read-only assessment of pipeline code; no external API calls or publication.

## Previously passing tests

- W00 scoping Python/R successful-response and HTTP error/retry controlled parity.
- W00–W08 static paths and reusable workflow input contract audit.
- W06/W07 synthetic first-run preparation manifests, and W08 included/excluded partition accounting, output integrity and checksums.

These tests do **not** constitute full end-to-end runtime validation.

## Current orchestration findings

1. **Blocking: W01 -> W02**. Both `workflow_01_production.yml` and `workflow_01_resume_after_human_review.yml` dispatch `workflow_02_batched_production.yml`, which is missing from the MVP branch. That wrapper exists on `workflow01-final-architecture` and delegates to `workflow_02_batched.yml`, which is also absent from the MVP branch. Do not simply relabel the dispatch: the available `workflow_02_production.yml` is a different implementation.
2. **Blocking: W02 -> W03**. The available `workflow_02_production.yml` has no W03 dispatch. The W02 human-resume workflow dispatches W03 after successful publication. The intended automatic versus adjudication handoff requires a design reconciliation.
3. **Deployment-only: branch references**. Several inactive workflows retain hard-coded `workflow01-final-architecture` checkout/push/dispatch references. Update these together at deployment; do not activate them independently.
4. **Retain: W08 -> W09**. Both W08 normal completion and W08 Shiny-resume dispatch `report_workflow09_figures.yml`. This handoff is required. W09's topic-specific report implementation will be replaced for another project.
5. W04 -> W05 -> W06 -> W07 -> W08 reusable workflow definitions are present and their static contract check passed.
6. W01 and W02 human resume paths remain part of the required validation scope.

## Remaining validation before calling the MVP end-to-end tested

- Reconcile the intended W02 batched/paused/resumed processing entry point and W03 launch, preserving human adjudication.
- Run synthetic W00 -> W01 -> W02 -> W03 -> W04 -> W05 -> W06 -> W07 -> W08 -> W09 fixtures through actual producers and consumers, not just independent stubs, including pointer JSON schemas, SHA-256/record-ID invariants and failure/restart cases.
- Validate runtime-generated pointers and Zenodo restoration contracts using local fixtures only.
- Validate W08 final canonical -> W09 inputs without invoking reporting publication.
- Check automatic resumed workflows use the same downstream handoffs as the uninterrupted pipeline.

This is an audit finding, not permission to copy deprecated production orchestration or make external writes.
