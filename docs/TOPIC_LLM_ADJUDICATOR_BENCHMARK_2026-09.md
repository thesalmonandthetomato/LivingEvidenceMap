# LLM third-pass topic adjudicator benchmark

Date: 2026-09-18

## Purpose

Test whether a fresh LLM can adjudicate disagreements between two independent ranked Luna topic-classification passes using:

- title;
- abstract;
- Pass A pathways, roles and reasons;
- Pass B pathways, roles and reasons;
- the full topic ontology;
- the ontology-first adjudication policy.

The model was blinded to the final manual decisions.

## Gold standard

The benchmark uses the 20 disagreements from the original 50-record ranked Luna benchmark that were manually adjudicated and agreed in:

`docs/topic_adjudication_ranked_luna_2026-09.csv`

The two records previously marked `needs_more_information` were excluded from the accuracy benchmark.

## Adjudicator design

Model: `gpt-5.6-luna`

Reasoning effort: `medium`

Two independent adjudicator requests were run.

Each request adjudicated all 20 records in one batch. The ontology was supplied once per batch. Structured output required final pathway/role assignments, status, pass alignment and rationale.

Gold-standard decisions were stored separately and were not supplied to the model.

Workflow run: `35349868345`

Artefact: `10549647191`

## Results

| Metric | Adjudicator 1 | Adjudicator 2 |
|---|---:|---:|
| Exact pathway-set match | 14/20 (70%) | 12/20 (60%) |
| Exact pathway + role match | 10/20 (50%) | 10/20 (50%) |
| Pathway precision | 0.941 | 0.939 |
| Pathway recall | 0.923 | 0.885 |
| Pathway F1 | 0.932 | 0.911 |
| Role accuracy on correctly recovered gold pathways | 0.917 | 0.935 |

Adjudicator-to-adjudicator self-consistency:

- exact pathway-set agreement: 15/20 (75%);
- exact pathway + role agreement: 12/20 (60%).

Agreement between the two adjudicator calls is therefore not sufficient evidence of correctness. Among the 15 cases in which their pathway sets agreed, only 11 matched the manual gold pathway set. Among the 12 cases with identical pathway+role output, only 8 matched the manual gold coding exactly.

## Important correlated errors

Both adjudicator calls made some of the same substantive ontology errors, including:

- omitting substantive diagnosis/detection (`V3_123`) from the ballan-wrasse bacterial study;
- adding firm strategy/business decision-making (`V3_024`) to the Big Fish valuation study despite the ontology boundary;
- classifying the sea-louse population-marker study as diagnostic/laboratory methods (`V3_046`) rather than sea-lice epidemiology (`V3_116`);
- retaining nutrient recovery (`V3_044`) in the blue-mussel/IMTA study.

The escape/post-escape record also showed instability: one adjudicator retained only `V3_013`, while the other retained only `V3_011`; the manual decision retained both as PRIMARY.

## Token use

Adjudicator 1:

- input tokens: 39,574;
- cache-write tokens: 39,571;
- output tokens: 3,281;
- reasoning tokens included in output usage: 1,609.

Adjudicator 2:

- input tokens: 39,574;
- cached input tokens: 39,571;
- output tokens: 3,160;
- reasoning tokens included in output usage: 1,441.

Total across both calls: 85,589 tokens.

Using GPT-5.6 Luna pricing current on 2026-09-18 ($0.20/M uncached input, $0.02/M cached input, $1.20/M output; cache writes billed at 1.25x uncached input), the approximate total cost of both batches was $0.0184, or about $0.00092 per record for two independent adjudications.

Pricing reference: https://developers.openai.com/api/docs/models/gpt-5.6-luna

## Interpretation

A third-pass LLM adjudicator improves pathway-level performance relative to either raw Luna pass on this disagreement subset, particularly for Adjudicator 1, but Luna is not accurate enough to serve as an unreviewed final adjudicator.

The principal limitation is not cost. It is correlated ontology error: independent adjudicator calls can agree with each other and still disagree with ontology-first manual adjudication.

The approach remains promising for:

1. proposing a final adjudication for human confirmation;
2. prioritising conflicts by apparent ambiguity;
3. reducing manual work when combined with validated ontology-specific rules;
4. benchmarking a stronger adjudicator model such as GPT-5.6 Terra or Sol.

It should not yet replace manual adjudication or validated rule-based resolution.
