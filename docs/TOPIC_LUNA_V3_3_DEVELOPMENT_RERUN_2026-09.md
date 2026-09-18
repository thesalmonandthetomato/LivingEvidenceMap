# Luna ontology v3.3 development rerun

Date: 2026-09-18

## Scope

Development/calibration rerun on the same 20 manually adjudicated conflicts. PRIMARY/SECONDARY performance is not used as the decision criterion in this iteration; evaluation focuses on pathway-set correctness and A/B pathway reproducibility.

Branch: `workflow06-gpt5mini-replication`

Workflow run: `35363547185`

Artefact: `10554663519`

## Change tested

The v3.2 wording for `V3_098` was retained unchanged. Only `V3_001` was sharpened:

> Assign V3_001 only when the paper makes a substantive claim or assessment about overall, general or cross-cutting environmental impact that cannot be restated completely as the set of specific environmental pathways coded. Do not assign V3_001 solely because a model, review or framework jointly analyses several specific environmental mechanisms.

## Pathway-set results

| Metric | v3.2 A | v3.2 B | v3.3 A | v3.3 B |
|---|---:|---:|---:|---:|
| Exact pathway-set match vs manual gold | 11/20 (55%) | 13/20 (65%) | 11/20 (55%) | 12/20 (60%) |
| Pathway precision | 0.918 | 0.977 | 0.933 | 0.958 |
| Pathway recall | 0.865 | 0.827 | 0.808 | 0.885 |
| Pathway F1 | 0.891 | 0.896 | 0.866 | 0.920 |

A/B exact pathway-set agreement under v3.3 was **13/20 (65%)**, unchanged from v3.2.

## Targeted V3_001 outcomes

### Broad LCA / seafood-awareness record

- gold includes `V3_001`;
- both v3.3 passes retained `V3_001`;
- Pass A recovered the complete gold pathway set;
- Pass B omitted `V3_034`, an error unrelated to the `V3_001` boundary.

### Simulation-model record

- gold excludes `V3_001` because `V3_005`, `V3_009` and `V3_010` fully represent the environmental content;
- both v3.3 passes excluded `V3_001`;
- both passes exactly matched the gold pathway set.

The revised wording therefore resolved the targeted broad-versus-specific `V3_001` contrast in both independent passes.

## Interpretation

The v3.3 change improved the intended `V3_001` boundary without reducing A/B pathway-set reproducibility. Aggregate performance remained variable between independent passes: v3.3 A had lower recall, while v3.3 B achieved the highest F1 observed in these development reruns (0.920). This variation arose mainly from omissions outside the targeted `V3_001` rule.

Retain the v3.2 `V3_098` clarification and the v3.3 `V3_001` wording. Further prompt tuning on these same 20 development records risks overfitting; the next step should be evaluation on an independent validation set.
