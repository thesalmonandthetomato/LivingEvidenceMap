# Terra third-pass topic adjudicator benchmark

Date: 2026-09-18

## Design

Identical blinded benchmark to the Luna third-pass adjudicator test:

- 20 manually adjudicated ranked Luna A/B conflicts;
- title and abstract;
- Pass A/B pathway-role assignments and reasons;
- full `topic_ontology_v3.csv`;
- identical adjudication system prompt;
- manual gold standard withheld from the model;
- two independent batch requests;
- model: `gpt-5.6-terra`;
- reasoning effort: medium.

Workflow run: `35354497637`

Artefact: `10551625781`

## Accuracy

| Metric | Terra adjudicator 1 | Terra adjudicator 2 |
|---|---:|---:|
| Exact pathway-set match | 16/20 (80%) | 14/20 (70%) |
| Exact pathway + role match | 12/20 (60%) | 12/20 (60%) |
| Pathway precision | 0.944 | 0.922 |
| Pathway recall | 0.981 | 0.904 |
| Pathway F1 | 0.962 | 0.913 |
| Role accuracy on correctly recovered gold paths | 0.902 | 0.957 |

Terra-to-Terra self-consistency:

- exact pathway-set agreement: 16/20 (80%);
- exact pathway + role agreement: 15/20 (75%).

## Comparison with Luna

Luna adjudicator results on the same benchmark:

| Metric | Luna 1 | Luna 2 |
|---|---:|---:|
| Exact pathway-set match | 14/20 (70%) | 12/20 (60%) |
| Exact pathway + role match | 10/20 (50%) | 10/20 (50%) |
| Pathway F1 | 0.932 | 0.911 |

Terra therefore improved the stronger run substantially, especially recall, but did not eliminate systematic ontology-boundary errors.

## Recurrent Terra errors

The following failures are important because several overlap with Luna failures or recur across both Terra calls:

- Blue-mussel / IMTA record: both Terra calls retained `V3_044` nutrient recovery, whereas manual ontology-first adjudication excluded it.
- Big Fish valuation: neither Terra call reproduced the gold `V3_027 PRIMARY; V3_023 SECONDARY`. Terra 1 returned only `V3_027`; Terra 2 returned only `V3_024`.
- Simulation models of finfish farms: both Terra calls retained broad `V3_001` alongside specific environmental pathways, contrary to the intended broad-vs-specific ontology boundary.
- Pressed/extruded feed record: Terra 1 added `V3_098` and promoted `V3_097`; Terra 2 omitted substantive `V3_112`.
- Escape/post-escape record: Terra 1 recovered both pathways but assigned `V3_011` SECONDARY rather than PRIMARY; Terra 2 omitted `V3_011`.
- RT-LAMP diagnostic-method record: both Terra calls made `V3_123` SECONDARY rather than co-primary.
- Patagonia record: both Terra calls downgraded `V3_056` livelihoods to SECONDARY rather than PRIMARY.
- Sea-louse population-marker record: Terra 1 correctly returned `V3_116`; Terra 2 repeated Luna's `V3_046` methods error.

These patterns indicate that model capability is only part of the problem.

## Token usage and cost

Terra adjudicator 1:

- input: 39,574 tokens;
- cache-write tokens: 39,571;
- output: 3,123 tokens.

Terra adjudicator 2:

- input: 39,574 tokens;
- cached input: 39,571;
- output: 3,567 tokens.

At OpenAI's short-context Terra prices current on 2026-09-18:

- uncached input: $1.00/M;
- cached input: $0.10/M;
- cache write: $1.25/M;
- output: $6.00/M.

Approximate total cost for both 20-record requests: **$0.0936**.

That is about **$0.00468 per record for two independent Terra adjudications**, or approximately $0.00234 per record for one.

## Interpretation

Terra is better than Luna as a third-pass adjudicator, but the residual error pattern strongly suggests that the present adjudication prompt / ontology presentation is contributing to mistakes.

The ontology itself is not necessarily substantively wrong: the manual gold standard was produced using the same ontology. However, presenting all ontology pathways in a single long prompt and asking for direct final coding appears insufficient to force correct use of critical `include_when` / `exclude_when` boundaries.

A more informative next experiment is therefore **not simply a stronger model**. It is an adjudication-prompt ablation using Terra:

1. current prompt + current ontology (already measured);
2. conflict-focused ontology retrieval: supply only the disputed pathways plus directly relevant neighbouring alternatives;
3. require the model to explicitly identify the governing ontology inclusion/exclusion criterion for each disputed pathway before producing final coding;
4. optionally add a small set of boundary examples derived from the development adjudications, but keep these separate from the independent validation set.

This will test whether prompt/ontology presentation, rather than model capacity, is the main remaining source of error.
