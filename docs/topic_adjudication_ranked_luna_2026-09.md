# Ranked Luna topic adjudication log

This log records human adjudication of the **22 actual disagreements** between the two ranked GPT-5.6 Luna passes in benchmark run **35318055832** (artefact **10536181345**).

The benchmark used the same fixed 50 records, the V4 substantive topic-coding rules, PRIMARY/SECONDARY role assignment, and the updated ontology including `V3_134 Biofouling and net fouling management`.

Only actual ranked A/B conflicts are included here. Historical coding is not treated as a gold standard.

## Agreed adjudications

| Record ID | Short title | Final coding | Rationale |
|---|---|---|---|
| 056-749-018-332-932 | Saprolegnia identification/genetic characterisation | `V3_121 PRIMARY; V3_123 SECONDARY` | Both role allocations were acceptable; epidemiology is the main contribution and diagnosis/detection is substantive but secondary. |
| 123-404-554-291-067 | Alternative dietary protein sources | `V3_096 PRIMARY; V3_112 SECONDARY; V3_113 SECONDARY` | Growth and metabolism are explicit substantive outcomes, not incidental measurements. |
| 099-035-316-344-435 | Blue mussels / salmon IMTA | `V3_110 PRIMARY; V3_043 PRIMARY; V3_005 SECONDARY; V3_020 SECONDARY` | IMTA and use of salmon waste by mussels are central; waste and mitigation are substantive secondary themes; `V3_044` excluded. |
| 002-142-200-779-757 | Hot smoking and EPA/DHA | `V3_072 PRIMARY; V3_078 PRIMARY` | Processing and compositional consequences are co-primary. |
| 032-215-431-747-456 | Amoebic gill disease pathology | `V3_120 PRIMARY; V3_123 SECONDARY; V3_132 SECONDARY` | Histopathology serves the disease question rather than constituting an independent anatomy/tissues topic. |
| 097-530-935-361-045 | Alexandrium bloom and salmon mortality | `V3_133 PRIMARY; V3_129 SECONDARY; V3_019 SECONDARY` | Mortality is a substantive bloom consequence and monitoring is a substantive response. |
| 032-384-942-689-849 | Nutrient-based growth model | `V3_049 PRIMARY` | Growth and physiology are modelled validation outcomes; methodological development is the principal contribution. |
| 033-811-323-921-83X | Marine growth and morphometrics | `V3_112 PRIMARY; V3_114 PRIMARY` | Growth and morphology are both explicit substantive objectives. |
| 142-901-874-742-548 | Patagonia Azul / Indigenous marine areas | `V3_062 PRIMARY; V3_056 PRIMARY; V3_067 SECONDARY` | Indigenous rights/governance and livelihoods are central; Indigenous knowledge is a substantive secondary theme. Neither pass alone was complete. |
| 038-353-098-644-720 | Ballan wrasse bacterial survey | `V3_121 PRIMARY; V3_123 SECONDARY` | Epidemiology is the primary contribution; bacterial identification/characterisation is independently substantive and secondary. Prefer Pass B. |
| 153-602-671-418-851 | RT-LAMP detection of IPNV | `V3_046 PRIMARY; V3_123 PRIMARY` | Method development/validation and IPNV diagnosis/detection are both central contributions. Prefer Pass A; low-cost role disagreement. |
| 021-344-006-899-928 | Life-cycle considerations for seafood awareness campaigns | `V3_004 PRIMARY; V3_001 SECONDARY; V3_034 SECONDARY` | Life-cycle/environmental assessment is primary; broad environmental impacts and certification/standards are substantive secondary themes. `V3_087` excluded because consumer response to labels is not itself investigated. Prefer Pass B. |
| 119-850-003-348-077 | Chilean salmon aquaculture and Alaskan sockeye markets | `V3_028 PRIMARY; V3_025 SECONDARY` | Supply, demand and prices are primary; revenues/earnings are explicit modelled outcomes and substantively secondary. Prefer Pass A. |
| 106-264-889-658-256 | Organic plant-protein replacement in trout feed | `V3_096 PRIMARY; V3_100 PRIMARY; V3_112 SECONDARY; V3_005 SECONDARY` | Alternative feed ingredients and nutrient utilisation are co-primary; growth is substantive secondary; nitrogen/phosphorus outputs are independently substantive environmental outputs. Prefer Pass B. |
| 128-953-506-234-897 | Huon Estuary environmental paper | **Unresolved** | No abstract or DOI available. Do not assign topics from title alone; retrieve abstract/full text before adjudicating `V3_001` versus no assignment. |
| 071-178-447-768-395 | Atlantic salmon SNP database | **Unresolved** | No abstract available in the benchmark data. Do not assign `V3_051` from title alone; retrieve abstract/full text before adjudication. |

## Audit correction

An earlier conversational assessment of the Patagonia Azul paper referred to an **older unranked disagreement**, not the ranked A/B conflict in this 22-record set. That mistaken assessment was not propagated. The ranked record was subsequently reviewed from its actual ranked outputs and is now recorded above.

## Adjudication rules

- **Do not assign topics from title alone.** If the abstract/full text is unavailable, leave the record unresolved and require further evidence before assigning substantive topics.

## Status

- Total ranked conflicts: **22**
- Agreed and recorded here: **14**
- Needs more information: **2**
- Pending: **6**
