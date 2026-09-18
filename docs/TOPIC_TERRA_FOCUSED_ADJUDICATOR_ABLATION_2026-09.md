# Focused-ontology Terra adjudicator ablation

Date: 2026-09-18

## Purpose

Test whether the residual errors in the Terra third-pass adjudicator are driven by presenting the full 134-path ontology in a single prompt.

## Design

Same blinded 20-record gold-standard benchmark as the full-ontology Terra test.

For each record, the adjudicator received:

- title and abstract;
- Pass A/B pathway-role assignments and reasons;
- every pathway proposed by either pass;
- all ontology pathways sharing `level_2` with any A/B-proposed pathway;
- explicit Definition / Include when / Exclude when / Interpretation note fields.

The prompt required an explicit KEEP/EXCLUDE criterion assessment for each disputed pathway before final coding.

Model: `gpt-5.6-terra`, medium reasoning.

Workflow run: `35356041653`

Artefact: `10551314558`

## Results

| Metric | Focused Terra 1 | Focused Terra 2 |
|---|---:|---:|
| Exact pathway-set match | 15/20 (75%) | 16/20 (80%) |
| Exact pathway + role match | 11/20 (55%) | 13/20 (65%) |
| Pathway precision | 0.927 | 0.944 |
| Pathway recall | 0.981 | 0.981 |
| Pathway F1 | 0.953 | 0.962 |
| Role accuracy on recovered gold pathways | 0.882 | 0.882 |

Self-consistency:

- exact pathway-set agreement: 19/20 (95%);
- exact full pathway+role agreement: 17/20 (85%).

## Comparison with full-ontology Terra

The best full-ontology Terra pass achieved:

- 16/20 exact pathway sets;
- 12/20 exact full ranked coding;
- pathway F1 0.962.

The focused version therefore did not improve maximum pathway accuracy, although it improved repeatability substantially and one run improved exact full ranked coding to 13/20.

## Persistent boundary errors

Focused ontology presentation did not resolve several recurring issues:

- `V3_044` nutrient recovery was still added to the blue-mussel/IMTA record;
- `V3_024` firm strategy/finance was still added to Big Fish valuation;
- `V3_112` growth was omitted from the pressed/extruded feed record;
- sea-louse population markers still received `V3_046` Methods, with `V3_116` demoted to secondary;
- several PRIMARY/SECONDARY boundaries remained systematically different from the manual ontology-first decision.

The criterion traces show that the model often retrieved the correct rule but interpreted substantive scope differently. For example, it correctly quoted that `V3_046` applies only when method development/validation/comparison is principal, but then treated the population-marker paper's marker utility as a principal laboratory-method contribution.

## Interpretation

The ablation suggests two separate effects:

1. **Prompt/ontology retrieval effect:** focusing the ontology materially improves adjudicator self-consistency.
2. **Operational-boundary effect:** some ontology definitions remain broad enough for a capable model to apply them differently from the intended manual interpretation.

The next ontology work should therefore clarify recurring boundaries on principled grounds rather than add record-specific exceptions. Candidate boundaries include:

- diagnostic/laboratory method development vs use of molecular markers to answer a biological/epidemiological question;
- economic valuation vs firm finance/business strategy;
- nutrient recovery vs biological uptake/IMTA use of waste-derived resources;
- general environmental impacts vs specific environmental pathways;
- explicit substantive secondary growth outcomes vs routine performance measurements.

Any ontology revision should be versioned and re-benchmarked on an independent set rather than silently tuned to the 20 development records.

## Token use

Focused Terra pass 1:

- input tokens: 32,527;
- cache-write tokens: 32,524;
- output tokens: 4,004.

Focused Terra pass 2:

- input tokens: 32,527;
- cached tokens: 32,524;
- output tokens: 4,316.

The focused prompt reduced input tokens relative to the full-ontology benchmark (39,574 per batch) but required somewhat more output because of the explicit criterion trace.
