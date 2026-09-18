# Ranked Luna adjudication analysis

## Scope

This analysis uses the fixed 50-record ranked Luna benchmark (run 35318055832) and the final ontology-first adjudications recorded in `docs/topic_adjudication_ranked_luna_2026-09.csv`.

Of 50 records:

- 28 had exact agreement between Pass A and Pass B on pathways and PRIMARY/SECONDARY roles.
- 22 had a ranked disagreement.
- 20 of those 22 were adjudicable from the available evidence.
- 2 remained unresolved because the benchmark lacked sufficient abstract/full-text evidence.

## Agreement structure

Across all 50 records:

- Full ranked exact A/B agreement: 28/50 = 56%.
- Pathway-set exact A/B agreement: 32/50 = 64%.
- Therefore 4/50 records had role-only disagreement.
- 18/50 records had at least one pathway inclusion disagreement.

Projected mechanically to 16,068 records, these benchmark rates would imply approximately:

- 7,070 records with some ranked A/B disagreement.
- 5,784 records with a pathway-set disagreement.

These are workload projections from a small benchmark, not population estimates.

## Which pass was closer to the final adjudication?

Among the 20 adjudicated disagreement records:

### Pathway-set exact agreement with final adjudication

- Pass A: 11/20
- Pass B: 12/20

### Full pathway + role exact agreement with final adjudication

- Pass A: 9/20
- Pass B: 7/20
- Neither pass exactly matched the final coding: 4/20

No pass dominates consistently enough to be designated authoritative.

Mean pathway performance against the final adjudications within the disagreement subset:

| Metric | Pass A | Pass B |
|---|---:|---:|
| Precision | 0.894 | 0.898 |
| Recall | 0.869 | 0.854 |
| F1 | 0.863 | 0.849 |

These values apply only to the 20 adjudicated conflict records and must not be interpreted as full-corpus accuracy estimates.

## Union and intersection are not sufficient adjudicators

On the 20 adjudicated disagreements:

### Union of Pass A and Pass B pathway sets

- Exact pathway match: 12/20
- Mean precision: 0.851
- Mean recall: 1.000
- Mean F1: 0.901

The union is deliberately recall-heavy but retains pathways that the ontology indicates should be excluded.

### Intersection of Pass A and Pass B pathway sets

- Exact pathway match: 9/20
- Mean precision: 0.900
- Mean recall: 0.723
- Mean F1: 0.785

The intersection removes too many legitimate secondary or co-primary pathways.

Therefore neither union nor intersection is an acceptable final reconciliation rule.

## Recurring disagreement patterns

The adjudications identify several recurring error modes.

### 1. Substantive secondary outcome versus incidental measurement

Examples include growth, metabolism, mortality, nutrient outputs and diagnosis/detection. The central distinction is whether the outcome is independently substantive under the ontology, not simply whether it was measured.

### 2. PRIMARY versus SECONDARY role instability

Four benchmark records had identical pathway sets but different roles. Most of these were relatively low-cost disagreements, but the role distinction still matters where the output is intended to communicate study emphasis.

### 3. Broad versus specific environmental coding

The broad `V3_001 Multiple or general environmental impacts` code can be over-assigned when specific environmental pathways are already identifiable. The ontology explicitly prefers specific pathways where one or more issues are substantively analysable.

### 4. Method versus substantive-domain research

A laboratory or modelling technique should receive a Methods pathway only when development, validation or comparison of the method is itself the principal contribution. Use of a method to answer a substantive biological or epidemiological question does not automatically justify a Methods code.

### 5. Contextual mention versus substantive topic

Trade, rural development, consumer labelling and similar concepts can appear in motivation or discussion without satisfying the ontology's substantive inclusion criteria.

### 6. Ontology labels can mislead if read without operational criteria

The `V3_023 Companies, ownership and concentration` example demonstrates that the `include_when` criterion may be broader than the short label. Adjudication must use the ontology fields, not shorthand labels.

### 7. Missing evidence must remain unresolved

Two conflicts could not be adjudicated because only titles were available. Topic assignment from titles alone is prohibited under the adjudication policy.

## Assessment of the two-pass approach

The two-pass Luna design is defensible as a **quality-control and disagreement-detection mechanism**. Its main strengths are:

- identical passes agree fully on 56% of benchmark records and on pathways on 64%;
- where they disagree, neither pass is systematically superior, so disagreement carries useful information;
- the disagreement set exposes genuine ontology-boundary decisions that a single pass would conceal;
- primary-path self-agreement is stronger than full ranked agreement, indicating greater stability for central themes than for secondary coding.

However, the benchmark does **not** support manually adjudicating every disagreement across 16,068 records. If the benchmark disagreement rate generalised, several thousand records would require review.

A production workflow should therefore preserve the two independent passes but add a scalable ontology-first adjudication layer. The adjudication layer must:

1. accept exact A/B agreements automatically;
2. preserve original A/B outputs and provenance;
3. apply explicit ontology-grounded rules to recurring conflict patterns;
4. alter shared assignments only for substantial ontology errors;
5. route genuinely ambiguous or evidence-deficient cases to manual review;
6. never resolve disagreements by blind union, intersection, or systematic preference for one pass.

The current 20 adjudications provide the seed examples for deriving and testing those rules, but the 50-record benchmark is too small to establish reliable population error rates. Before committing to full-corpus processing, the rule set should be tested on a larger independent sample of disagreements.
