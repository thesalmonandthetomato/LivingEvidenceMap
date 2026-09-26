# Workflow 04: ad hoc actions and baseline-establishment log

## Purpose

This document records non-routine actions used while establishing the current validated Workflow 04 baseline.

These actions are **not part of the Workflow 04 production methodology** and should not be described as normal Workflow 04 behaviour in methods reporting. The production workflow is documented separately in:

`docs/reporting/workflow_04/workflow_04_functionality_map.md`

This log exists to preserve provenance, explain how previously completed work was reused without unnecessary API reruns, and distinguish baseline-establishment decisions from the durable workflow architecture.

## 1. Historical screening migration

A previously completed Workflow 04 screening corpus was reconciled to the new canonical work identities.

The migration identified:

- 22,198 canonical records with a safely recoverable historical retain/exclude decision;
- 24 canonical records whose historical manifestations carried conflicting previous screening decisions;
- 10,061 genuinely novel W03-eligible records; and
- no unexplained residual historical records after identity reconciliation.

The 24 historical mapping-conflict records were excluded from the safe historical-decision layer.

The migration was a one-off provenance/reuse operation. It is not part of future Workflow 04 screening.

## 2. Decision to rescreen the complete W03-eligible corpus

Although 22,198 safe previous screening decisions were available, the current baseline was screened afresh with Luna over the complete 32,283-record W03-eligible corpus.

The historical decisions were retained as a comparison layer rather than being counted as model votes.

This enabled direct assessment of model-pass reproducibility and agreement with previous screening.

## 3. Shard-7 runner interruption and recovery

The first full consensus run was GitHub Actions run `36186630247`.

Seven of eight deterministic shards completed successfully. Shard 7 was interrupted by a GitHub runner shutdown signal after substantial pass-1 processing. The failure was not an API, model or screening-code error.

Completed shard outputs were preserved rather than rerun.

Original shard 7 was deterministically subdivided into four smaller recovery subshards and rerun through:

`Workflow 04 - recover shard 7 consensus`

Recovery run:

`36221408684`

All four recovery subshards and the recovered merge passed. The final recovered model-consensus layer contained all 32,283 W03-eligible records.

This recovery procedure was an execution-resilience action, not a methodological change to screening.

## 4. Use of safe historical decisions for Luna-unresolved records

The recovered Luna consensus contained 691 unresolved records.

Among these, 248 records already had one safe historical retain/exclude decision:

- 122 historical retain;
- 126 historical exclude.

Those previous decisions were used to resolve these records without additional manual rescreening.

This was a one-off reuse of already completed human/model screening work and is not part of the production consensus algorithm.

## 5. One-off Terra adjudication

After applying the safe historical decisions above, 443 Luna-unresolved records remained without a safe previous decision.

These records were submitted once to `gpt-5.6-terra` using the **identical immutable Workflow 04 prompt**.

One-off Terra run:

`36225691899`

Results:

- 41 retain;
- 148 exclude;
- 254 uncertain;
- 0 technical failures.

Terra was used only as a one-off workload-reduction adjudicator. It is not part of the Workflow 04 production architecture.

## 6. Rule-based audit of the 254 Terra-uncertain records

The 254 records remaining uncertain after Terra were audited against the two required eligibility gates:

1. eligible species or explicit relevant salmon-farming context; and
2. commercial aquaculture relevance.

The residual set did not establish both gates from the supplied bibliographic metadata. The full 254-record set was therefore adjudicated as exclude.

This was an explicit human-approved baseline decision and not an automated Workflow 04 rule added to the model pipeline.

## 7. Historical EXCLUDE decisions carried forward

Agreement analysis identified 704 records where a substantive Luna consensus differed from the safe historical screening decision:

- 360 historical RETAIN → Luna EXCLUDE;
- 344 historical EXCLUDE → Luna RETAIN.

Following manual inspection of examples and acceptance of the observed model disagreement rate, the previous safe historical EXCLUDE decisions were treated as authoritative for the 344 cases where Luna had newly retained a previously excluded record.

Historical retains were not used to override Luna excludes.

This is a baseline-preservation decision applied to known previous exclusions. It is not part of the generic 2-of-3 Luna consensus rule for future records.

The final reconciliation run applying this decision was:

`36227737500`

## 8. Agreement audit

Agreement statistics were calculated from the **original model outputs before historical decisions were used to override or resolve final classifications**.

This avoids circularly inflating agreement.

Key results:

- pass 1 vs pass 2, all 32,283 records: 96.31% agreement, Cohen's κ = 0.925;
- pass 1 vs pass 2, substantive binary decisions only: 98.32% agreement, Cohen's κ = 0.964;
- final Luna consensus vs safe historical substantive decisions: 96.79% agreement, Cohen's κ = 0.922;
- historical/pass-1/pass-2 three-rater Fleiss' κ = 0.935;
- 96.01% unanimous agreement across the 21,798 records contributing to that three-rater statistic.

The complete machine-readable agreement summary is stored at:

`docs/workflow04/workflow04_agreement_summary.json`

The reproducible calculation is:

`scripts/updater/workflow_04_agreement_audit.R`

## 9. Final validated baseline

After all baseline-establishment adjudications:

- W03-eligible records: 32,283;
- retained: 19,407;
- excluded: 12,876;
- unresolved: 0;
- inclusion rate: 60.12%.

The final validated reconciliation run is:

`36227737500`

## Reporting rule

For Workflow 09 and manuscript methods:

- use `workflow_04_functionality_map.md` to describe **what Workflow 04 does**;
- use the agreement statistics as validation/performance evidence where relevant;
- do not describe the historical migration, runner recovery, Terra one-off adjudication, residual bulk exclusion or historical-exclude override as normal production Workflow 04 stages;
- cite this ad hoc log only when documenting the provenance of the current baseline or explaining deviations during baseline establishment.

Future one-off repairs, recoveries or inherited-data actions affecting Workflow 04 should be appended here rather than incorporated into the methodological workflow report unless they are deliberately adopted as permanent workflow architecture.
