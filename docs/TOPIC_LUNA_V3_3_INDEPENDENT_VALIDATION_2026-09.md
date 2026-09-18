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

## Joint adjudication

The three pathway-set disagreements were reviewed jointly with the project lead against the title, abstract and v3.3 ontology guidance. Exact A/B pathway-set agreements were retained under the agreed procedure. Historical coding was used only as context, not as a gold standard. PRIMARY/SECONDARY-only differences were excluded from the pathway-level performance assessment.

| Record | Final pathway set | Decision |
|---|---|---|
| Environmental issues in fish farming review (\`134-544-977-859-631\`) | \`V3_001; V3_016; V3_020\` | Include broad environmental assessment, ecosystem and wild-species effects, and environmental mitigation. Exclude \`V3_032\` because regulation is reported as a response rather than analysed as a governance question. |
| Selectively bred trout for BCWD resistance (\`052-497-365-338-585\`) | \`V3_089; V3_122\` | Selective breeding is central and is explicitly evaluated as a disease-control strategy. |
| Anaerobic treatment of fish-farm sludge (\`003-201-232-625-748\`) | \`V3_005; V3_020; V3_043\` | Sludge treatment is central, full-scale treatment recommendations constitute mitigation, and methane or energy production is substantive waste valorisation. |

### Performance against the resulting adjudicated sets

| Metric | Luna A | Luna B |
|---|---:|---:|
| Exact pathway-set matches | 17/20 (85%) | 18/20 (90%) |
| Pathway precision | 1.000 | 1.000 |
| Pathway recall | 0.875 | 0.938 |
| Pathway F1 | 0.933 | 0.968 |
| False positives | 0 | 0 |
| False negatives | 4 | 2 |

All observed errors were omissions. No false-positive pathway was observed. These results support retaining v3.3 unchanged for the next independent batch. This is an agreement-plus-disagreement adjudication benchmark, not a fully independently adjudicated gold-standard study.

## Second independent batch

A further 20 records were selected deterministically from the authoritative master after excluding all 50 records in the original benchmark. Each selected record had a usable title and abstract. The v3.3 prompt and ontology were unchanged.

Workflow run: `35369637629`

Artefact: `10557651500`

Source master SHA-256: `36f9f8eb966e2bd01b7bb309ed3f685215c1e13065f36d2233abb237f5f911e2`

Queue SHA-256: `516db36eec8ee1e13ba45700febfad77c97c5ff24482e884adbd93ce3155df8c`

### Reproducibility

| Metric | Result |
|---|---:|
| Exact pathway-set agreement | 13/20 (65%) |
| Mean pathway-set Jaccard similarity | 0.844 |
| Pathway F1 between passes | 0.886 |
| Exact full-ranked agreement | 11/20 (55%) |

Seven pathway-set disagreements were jointly adjudicated. A further exact-agreement record was corrected because both passes assigned a General disease code alongside its more specific diagnostic sibling, contrary to the subsequently clarified General-code rule.

### Joint adjudication decisions

| Record | Final pathway set |
|---|---|
| Pancreas-disease resistance families (`79870`) | `V3_089; V3_113; V3_120; V3_129` |
| Salmon and catfish allergens (`80052`) | `V3_082; V3_083` |
| Cardiomyopathy-syndrome outbreak (`75382`) | `V3_121` |
| Dietary glutamine in rainbow trout (`002-745-592-254-687`) | `V3_076; V3_097; V3_101; V3_112; V3_113` |
| Carnobacterium infections (`77738`) | `V3_121; V3_123` |
| PUFA concentrate from trout by-product (`73358`) | `V3_043; V3_078; V3_079` |
| Fishmeal and fish-oil replacement (`73968`) | `V3_096; V3_112; V3_113` |
| Dual ISA/togavirus-like infection (`77091`) | `V3_123` |

### Performance against the resulting adjudicated sets

| Metric | Luna A | Luna B |
|---|---:|---:|
| Exact pathway-set matches | 16/20 (80%) | 14/20 (70%) |
| Pathway precision | 0.946 | 0.970 |
| Pathway recall | 0.946 | 0.865 |
| Pathway F1 | 0.946 | 0.914 |
| False positives | 2 | 1 |
| False negatives | 2 | 5 |

The lower raw A/B agreement therefore did not translate into poor performance against the resulting adjudicated sets. Luna A was more complete in this batch, while Luna B remained more conservative. The additional exact-agreement correction also demonstrates that A/B agreement alone cannot guarantee correctness.

The General-code decisions led to v3.4: General pathways are exclusive fallbacks when a more specific sibling pathway applies. Ontology v3.3 and its outputs remain unchanged for reproducibility. The same 20-record queue is rerun under v3.4 to isolate the effect of this change.

