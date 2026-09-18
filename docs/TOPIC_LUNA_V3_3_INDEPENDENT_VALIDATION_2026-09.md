# Luna ontology v3.3 independent validation

Date: 2026-09-18

## Scope

Two independent Luna v3.3 passes on 20 records held out from prompt development. All 22 records previously considered during development were excluded, including the 20 agreed cases and two unresolved cases. Twenty records were selected deterministically from the 28 remaining records by a recorded SHA-256 ordering.

Branch: `workflow06-gpt5mini-replication`

Workflow run: `35364774821`

Artefact: `10556455102`

Queue SHA-256: `a990723e1ef8db304e200dbe8d8dd6b194a2857276a6a64142cfa960c0f475d8`

## Reproducibility results

| Metric | Result |
|---|---:|
| Exact pathway-set agreement | 17/20 (85%) |
| Mean pathway-set Jaccard similarity | 0.917 |
| Pathway F1 between passes | 0.931 |
| Exact full ranked agreement | 15/20 (75%) |

The three pathway-set disagreements were:

1. Environmental-issues review: Pass A assigned `V3_020`; Pass B assigned `V3_016`.
2. On-farm selectively bred trout: Pass B additionally assigned `V3_122`.
3. Anaerobic sludge treatment: Pass B additionally assigned `V3_043`.

Two further records had identical pathway sets but PRIMARY/SECONDARY disagreements. These role differences are recorded but are not used as the decision criterion for this validation.

## Historical-assignment diagnostic

Each Luna pass exactly matched the historical pathway set for 6/20 records (30%). This is not an accuracy estimate: the historical assignments have not been manually adjudicated and may be incomplete or overinclusive. The validation artefact therefore includes a review queue containing titles, abstracts, historical assignments, both Luna outputs and reasons for subsequent blinded human adjudication.

## Interpretation

Pathway-set reproducibility improved from 13/20 (65%) on the development set to 17/20 (85%) on the independent held-out sample. This supports the stability of v3.3, but pathway-set correctness cannot be estimated until the 20 held-out records receive a manual gold-standard adjudication independent of the two Luna outputs.
