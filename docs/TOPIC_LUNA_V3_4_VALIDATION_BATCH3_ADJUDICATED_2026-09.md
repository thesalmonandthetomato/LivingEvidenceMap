# Luna ontology v3.4 validation batch 3 adjudication

Date: 2026-09-18

## Scope and method

Two independent Luna v3.4 passes classified a fresh deterministic sample of 20 records. The original 50-record benchmark and the previous 20-record validation batch were excluded before sampling. Exact pathway-set agreements were retained; the three genuine pathway-set disagreements were reviewed with the project lead and then sent to Terra for independent third-model adjudication.

Terra received each record's ID, title and abstract, both Luna pathway assignments and reasons, and the full v3.4 ontology. Historical coding and the human final decisions were withheld. Terra was instructed to assess each pathway independently, not presume either pass correct, not automatically take the union, and treat General codes as exclusive fallbacks where no more specific sibling applies.

PRIMARY/SECONDARY-only differences were recorded but were not adjudication criteria.

Branch: `workflow06-gpt5mini-replication`

Luna workflow run: `35390150712`

Luna artefact: `10565511758`

Luna artefact SHA-256: `8e6805e9f9a227c4b225eb3f743020e258665d1d2f15ceb902c99f2d2f48fb1a`

Queue SHA-256: `f781929c9ca49ba056f71b41c4f39908f23a7874a8da02b3c940ec923f09e05e`

Terra workflow run: `35392833002`

Terra artefact: `10566885674`

Terra artefact SHA-256: `14f7ba46a1158308ef387f697bdf67078f9ee272333259b3ad443ee805a969d6`

Terra model: `gpt-5.6-terra`, reasoning effort `medium`

## Reproducibility before adjudication

| Metric | Result |
|---|---:|
| Exact pathway-set agreement | 17/20 (85%) |
| Mean pathway-set Jaccard similarity | 0.9375 |
| Pathway F1 between passes | 0.960 |
| Exact full ranked agreement | 12/20 (60%) |

There were three pathway-set disagreements and five additional role-only differences. Luna A made 37 pathway assignments and Luna B made 38. Across the pathway-set disagreements, A had one A-only pathway and B had two B-only pathways.

## Adjudication decisions

| Record | Luna A | Luna B | Human final | Terra final | Result |
|---|---|---|---|---|---|
| Welfare phenotyping under poor water quality (`74273`) | `V3_125; V3_126; V3_132` | `V3_115; V3_125; V3_126; V3_132` | `V3_115; V3_125; V3_126; V3_132` | `V3_115; V3_125; V3_126; V3_132` | Exact match; no Terra review flag. Behaviour, cognition, welfare hazards and water conditions are all substantive. |
| Temperature as an AGD outbreak risk factor (`82979`) | `V3_121; V3_132` | `V3_121` | `V3_121; V3_132` | `V3_121; V3_132` | Exact match; no Terra review flag. Both disease epidemiology and water temperature are substantive. |
| Amoebic gill infection in Korean coho salmon (`77119`) | `V3_123` | `V3_121; V3_123` | `V3_121; V3_123` | `V3_121; V3_123` | Exact match; no Terra review flag. Disease occurrence and pathogen identification are substantive; General `V3_120` is excluded because specific sibling pathways apply. |

Terra independently matched all three human decisions: 3/3 exact pathway sets, with no review flags.

## Performance against the adjudicated sets

The 17 exact A/B agreements were retained and the three disagreements use the human final sets above.

| Metric | Luna A | Luna B |
|---|---:|---:|
| Exact pathway-set matches | 18/20 (90%) | 19/20 (95%) |
| Pathway precision | 1.000 | 1.000 |
| Pathway recall | 0.949 | 0.974 |
| Pathway F1 | 0.974 | 0.987 |
| True positives | 37 | 38 |
| False positives | 0 | 0 |
| False negatives | 2 | 1 |

All observed pathway errors were omissions. No false-positive pathway was observed. This does not independently validate the 17 exact A/B agreements, which were retained without separate human or third-model review.

## Interpretation

The third-model check supports all three human resolutions and provides no evidence of a systematic false-positive problem in this batch. The remaining error pattern is sparse omission, especially where one record substantively spans two or more ontology pathways. The General-code exclusivity clarification behaved as intended for record `77119`: the more specific disease pathways were retained and the General sibling was excluded.

This remains an agreement-plus-disagreement adjudication benchmark, not a fully independently adjudicated gold-standard accuracy study. Raw Terra responses, prompts and the provenance manifest are retained in artefact `10566885674`.
