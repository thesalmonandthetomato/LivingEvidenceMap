# Workflow 04 final screening summary

## Final screening outcome

Workflow 04 relevance screening was completed on the 32,283 records eligible after Workflow 03 publication-status filtering.

Final decision counts after reconciliation:

- Retain: 19,407
- Exclude: 12,876
- Unresolved: 0
- Final inclusion rate: 60.12%

The final decision layer preserves decision provenance. Fresh Luna consensus remained the primary screening route. Safe historical EXCLUDE decisions were carried forward as authoritative where they conflicted with a Luna RETAIN decision. Historical decisions were also used as fallback where Luna remained unresolved. A one-off Terra adjudication was used only for Luna-unresolved records lacking a safe historical decision, and the residual 254 Terra-uncertain records were excluded after a rule-based audit established that the supplied metadata did not establish both an eligible species/relevant salmon-farming context and commercial aquaculture relevance.

Source runs:
- recovered Luna consensus: 36221408684
- one-off Terra adjudication: 36225691899
- final W04 reconciliation with historical EXCLUDE overrides: 36227737500

## Agreement and reliability audit

Agreement statistics were calculated on the original model outputs **before historical decisions were used to override or resolve model decisions**. This prevents circular inflation of agreement.

The safe historical comparison layer contained 22,198 records with a single definitive previous retain/exclude decision. The 24 historical mapping-conflict cases were not included in this comparator.

### Luna pass-to-pass reproducibility

Across all 32,283 W03-eligible records:

| Comparison | n | Exact agreement | Cohen's kappa |
|---|---:|---:|---:|
| Luna pass 1 vs Luna pass 2, retaining `uncertain` as a third category | 32,283 | 96.31% | 0.925 |
| Luna pass 1 vs Luna pass 2, both passes substantive retain/exclude | 31,225 | 98.32% | 0.964 |

A total of 1,058 records had `uncertain` from at least one of the first two Luna passes. A further 525 records had opposing substantive retain/exclude decisions. These 1,583 records formed the third-pass queue.

### Luna versus safe historical decisions

| Comparison | n | Exact agreement | Cohen's kappa | Luna uncertain excluded from binary comparison |
|---|---:|---:|---:|---:|
| Pass 1 vs historical, all shared records with `uncertain` retained as a category | 22,198 | 95.54% | 0.893 | n/a |
| Pass 1 vs historical, substantive Luna decisions only | 21,936 | 96.69% | 0.919 | 262 |
| Pass 2 vs historical, all shared records with `uncertain` retained as a category | 22,198 | 95.44% | 0.891 | n/a |
| Pass 2 vs historical, substantive Luna decisions only | 21,934 | 96.59% | 0.917 | 264 |
| Final Luna consensus vs historical, all shared records with unresolved retained as a category | 22,198 | 95.71% | 0.897 | n/a |
| Final Luna consensus vs historical, substantive consensus decisions only | 21,950 | 96.79% | 0.922 | 248 |

For the 21,950 records where both the safe historical screening and final Luna consensus yielded a substantive retain/exclude decision, 21,246 agreed and 704 disagreed:

- 360 historical RETAIN -> Luna EXCLUDE
- 344 historical EXCLUDE -> Luna RETAIN

The remaining 248 historical records were unresolved by Luna consensus:
- 122 historical RETAIN
- 126 historical EXCLUDE

### Three-rater agreement

For the 21,798 records where the historical decision, Luna pass 1 and Luna pass 2 were all substantive retain/exclude decisions:

- Fleiss' kappa across the three raters: **0.935**
- unanimous three-way agreement: **96.01%** (20,928/21,798)

This provides a single multi-rater reliability estimate without using the historical decision to alter either Luna pass.

### Third-pass subset

Pass 3 was not applied to a random or representative sample. It was invoked only for records where passes 1 and 2 disagreed, returned `uncertain`, or encountered a technical issue. Its agreement statistics therefore describe a deliberately difficult subset and must not be compared directly with the full-pass statistics.

Among the 736 third-pass records that also had a safe historical decision:

| Comparison | n | Exact agreement | Cohen's kappa |
|---|---:|---:|---:|
| Pass 3 vs historical, with `uncertain` retained as a category | 736 | 48.10% | 0.172 |
| Pass 3 vs historical, substantive pass-3 decisions only | 549 | 64.48% | 0.290 |

Pass 3 returned `uncertain` for 187/736 historical-comparator records. The low kappa in this subset is expected from the selection mechanism: these records were sent to pass 3 precisely because the first two classifications were unstable or uncertain.

## Interpretation for Workflow 09

The main validation statistics to carry into Workflow 09 are:

- Luna pass-to-pass agreement: **96.31%, Cohen's kappa 0.925** across all 32,283 records.
- Binary pass-to-pass agreement where both passes were substantive: **98.32%, Cohen's kappa 0.964**.
- Final Luna consensus versus previous safe screening decisions: **96.79%, Cohen's kappa 0.922** across 21,950 substantive paired decisions.
- Three-rater historical/pass-1/pass-2 reliability: **Fleiss' kappa 0.935**, with **96.01% unanimous agreement** across 21,798 records.
- The 704 substantive Luna-versus-historical conflicts represent **3.21%** of the 21,950 comparable substantive decisions.
- Third-pass agreement statistics should be labelled as results from a selectively enriched difficult subset, not as overall screening accuracy or reliability.

These statistics quantify **screening consistency and agreement**, not evidential strength and not model accuracy against an independent gold standard. The historical decisions are previous screening decisions used as a comparator, not an independent reference standard.
