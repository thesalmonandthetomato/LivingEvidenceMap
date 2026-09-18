# Luna ontology v3.1 development rerun

Date: 2026-09-18

## Scope

This is a **development/calibration test**, not an independent validation.

The same 20 manually adjudicated conflicts used to identify ontology-boundary problems were rerun through two independent GPT-5.6 Luna classification passes after:

- creating `data/reference/topic_ontology_v3_1.csv` with agreed boundary clarifications;
- strengthening the global PRIMARY/SECONDARY prompt rule in `R/run_topic_v4_classifier_ranked_v3_1.R`.

The original v3 ontology and original runner remain unchanged.

Workflow run: `35358057071`

Artefact: `10554135157`

## Overall results

### Against manual gold

| Metric | Original v3 A | Original v3 B | v3.1 A | v3.1 B |
|---|---:|---:|---:|---:|
| Exact pathway set | 11/20 (55%) | 12/20 (60%) | 10/20 (50%) | 11/20 (55%) |
| Exact pathway + role | 9/20 (45%) | 7/20 (35%) | 7/20 (35%) | 7/20 (35%) |
| Pathway precision | 0.900 | 0.902 | **0.938** | **0.936** |
| Pathway recall | 0.865 | 0.885 | 0.865 | 0.846 |
| Pathway F1 | 0.882 | 0.893 | **0.900** | 0.889 |

### A/B self-consistency

On these 20 records, the original v3 runs were selected because they were ranked disagreements:

- original exact pathway-set A/B agreement: 4/20;
- original exact pathway + role A/B agreement: 0/20.

With ontology v3.1:

- exact pathway-set A/B agreement: **14/20 (70%)**;
- exact pathway + role A/B agreement: **14/20 (70%)**.

Thus v3.1 greatly reduced stochastic disagreement, but did not improve exact agreement with manual gold overall.

## Boundary-specific effects

### Clear improvements

#### V3_043 / V3_044: waste as input vs nutrient recovery

Blue-mussel/IMTA record:

- gold: exclude V3_044;
- original: Pass A included V3_044 SECONDARY, Pass B excluded;
- v3.1: **both passes excluded V3_044**.

The clarification worked as intended.

#### V3_024 / V3_027: firm strategy vs economic valuation

Big Fish valuation:

- gold: V3_027 PRIMARY; no V3_024;
- original: Pass A used V3_024 PRIMARY and omitted V3_027; Pass B used V3_027 PRIMARY;
- v3.1: **both passes used V3_027 PRIMARY and excluded V3_024**.

The valuation/strategy boundary worked as intended.

#### V3_001: broad vs specific environmental pathways

Simulation models of finfish farms:

- gold: specific V3_005/V3_009/V3_010 plus V3_049; no V3_001;
- original: Pass B added V3_001 PRIMARY;
- v3.1: **both passes excluded V3_001**.

The broad-vs-specific rule worked for this intended case.

#### V3_046 / V3_116: Methods vs sea-louse population epidemiology

Sea-louse population-marker record:

- gold: V3_116 PRIMARY; no V3_046;
- original: Pass B used V3_046 PRIMARY;
- v3.1: **both passes used V3_116 PRIMARY and excluded V3_046**.

This is a strong success of the clarified boundary.

### Regressions / remaining ambiguity

#### V3_098: nutrient requirements/formulation

Alternative-protein record:

- gold: no V3_098;
- original: neither pass assigned V3_098;
- v3.1: **both passes assigned V3_098 SECONDARY**.

The revised wording appears to have made graded ingredient-replacement levels look like formulation optimisation. This is contrary to the intended boundary.

Pressed/extruded feed record:

- gold: no V3_098;
- v3.1 A assigned V3_098 PRIMARY while v3.1 B correctly excluded it.

V3_098 therefore needs another clarification: testing ingredient replacement levels or comparing complete diets is not nutrient-requirement/feed-formulation research unless the study explicitly seeks to define a nutrient requirement, optimise nutrient concentration/balance, or formulate a diet against a nutritional target.

#### V3_001: integrated broad environmental assessment

Seafood awareness/LCA record:

- gold: V3_004 PRIMARY; V3_001 SECONDARY; V3_034 SECONDARY;
- original: both passes retained V3_001 SECONDARY;
- v3.1 A omitted V3_001; v3.1 B promoted it to PRIMARY.

The categorical v3.1 wording is too blunt. It successfully prevents redundant V3_001 in specific-pathway studies, but destabilises genuine broad integrated environmental-assessment records.

A better boundary is:

- exclude V3_001 when multiple specific environmental pathways fully represent the substantive environmental content;
- retain V3_001 when broad/multiple environmental impacts are themselves an integrated substantive object of assessment that is not exhausted by the specific pathways;
- use SECONDARY where such broad framing is substantive but subordinate to a specific integrated method such as LCA.

## Remaining errors not fixed by the revised pathway boundaries

Several disagreements concern substantive secondary coding or roles rather than the revised pathway boundaries:

- Saprolegnia: one pass still omitted V3_123 diagnosis/detection;
- ballan wrasse: both passes omitted substantive V3_123;
- Alaska markets: both omitted V3_025 revenues/earnings;
- RT-LAMP: both retained V3_123 but made it SECONDARY rather than co-primary;
- Patagonia: both shifted V3_056 livelihoods to SECONDARY and V3_067 knowledge to PRIMARY;
- escape/post-escape: both made V3_011 SECONDARY rather than co-primary;
- pressed/extruded feed: roles and secondary outcome coverage remain unstable.

## Conclusion

The v3.1 changes demonstrate that clearer ontology boundaries can substantially improve model self-consistency and successfully correct several known systematic errors.

However, v3.1 should **not** be promoted unchanged. Two areas require further principled clarification before independent validation:

1. `V3_098` nutrient requirements/feed formulation vs graded ingredient replacement or comparison of complete diets;
2. `V3_001` broad integrated environmental assessment vs redundant use alongside specific pathways.

The development rerun also confirms that role assignment and substantive-secondary detection remain separate problems from pathway-boundary wording.
