# Luna ontology v3.2 development rerun

Date: 2026-09-18

## Scope

Development/calibration rerun on the same 20 manually adjudicated conflicts. PRIMARY/SECONDARY performance is not used as the decision criterion in this iteration; evaluation focuses on pathway-set correctness and A/B pathway reproducibility.

Workflow run: `35359105791`

Artefact: `10554396539`

## Pathway-set results

| Metric | Original v3 A | Original v3 B | v3.2 A | v3.2 B |
|---|---:|---:|---:|---:|
| Exact pathway-set match vs manual gold | 11/20 (55%) | 12/20 (60%) | 11/20 (55%) | **13/20 (65%)** |
| Pathway precision | 0.900 | 0.902 | 0.918 | **0.977** |
| Pathway recall | 0.865 | 0.885 | 0.865 | 0.827 |
| Pathway F1 | 0.882 | 0.893 | 0.891 | **0.896** |

A/B pathway-set agreement under v3.2 was **13/20 (65%)**.

## Targeted boundary outcomes

### V3_098 nutrient requirements / formulation

The v3.2 clarification worked as intended.

Alternative-protein record:

- gold: no V3_098;
- v3.2 A: no V3_098;
- v3.2 B: no V3_098.

Pressed/extruded-feed record:

- gold: no V3_098;
- neither v3.2 pass assigned V3_098.

The v3.2 wording should therefore be retained.

### V3_001 broad environmental issues

The v3.2 correction did not resolve the boundary.

Seafood-awareness/LCA record:

- gold pathway set includes V3_001;
- both v3.2 passes retained V3_001.

This is desirable at pathway-set level.

However, simulation-model record:

- gold excludes V3_001 because specific environmental pathways fully represent the substantive environmental content;
- both v3.2 passes assigned V3_001.

Thus the revised wording again permits redundant broad coding when multiple specific pathways are integrated in one modelling framework.

## Interpretation

v3.2 improves the V3_098 boundary without apparent regression and should retain that change.

V3_001 still requires a sharper operational distinction between:

1. a **broad environmental assessment as an independent object of analysis**, where V3_001 should be retained; and
2. an **integrated study/model spanning multiple specific environmental pathways**, where those specific pathways should be sufficient and V3_001 should be excluded.

The distinction should not rely merely on the fact that multiple pathways are integrated. A candidate operational test is:

> Assign V3_001 only when the paper makes a substantive claim or assessment about overall, general or cross-cutting environmental impact that cannot be restated completely as the set of specific environmental pathways coded. Do not assign V3_001 solely because a model, review or framework jointly analyses several specific environmental mechanisms.

This should be tested again on the development set before independent validation.
