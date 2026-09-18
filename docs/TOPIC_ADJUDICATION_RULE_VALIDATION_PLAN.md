# Candidate adjudication-rule validation plan

## Purpose

Validate `data/reference/topic_adjudication_rules_v1.json` on an **independent set of ranked Luna A/B disagreements** before any rule is used to adjudicate the full 16,068-record corpus.

## Design

1. Run the frozen two-pass Luna classifier using the same ontology, prompt, model and reasoning settings.
2. Identify A/B disagreements.
3. Exclude all 50 records from the original ranked Luna benchmark, including the 22 conflicts used to derive the candidate rules.
4. Draw a reproducible random sample of **at least 100 disagreements**, preferably **200**.
5. Preserve the sampling seed and the complete source disagreement table.
6. Manually adjudicate each sampled record using `topic_adjudication_policy_v1.json` and the ontology, without consulting the candidate-rule output where practicable.
7. Apply the candidate rules independently.
8. Compare rule output against manual adjudication.

## Required outputs

For every validation record retain:

- record ID and title from the authoritative source table;
- abstract/full-text evidence status;
- Pass A pathways/roles/reasons;
- Pass B pathways/roles/reasons;
- disputed pathways/roles;
- candidate rule(s) triggered;
- candidate-rule decision;
- manual ontology-first decision;
- exact-match indicators;
- pathway TP/FP/FN;
- whether manual review would still be required;
- adjudication rationale.

## Metrics

Report:

- exact pathway-set agreement;
- exact pathway + role agreement;
- pathway precision;
- pathway recall;
- pathway F1;
- proportion resolved automatically;
- proportion still requiring manual review;
- errors by candidate rule;
- false inclusion and false exclusion counts by pathway;
- PRIMARY/SECONDARY role errors separately.

## Integrity requirements

- Do not manually transcribe record IDs.
- Join all decisions back to the authoritative disagreement table programmatically.
- Preserve raw inputs and intermediate outputs.
- Fail validation if any record-ID/title pair does not match its source.
- Do not alter the candidate rule file after manual adjudication begins without incrementing its version and restarting validation.
- Do not use any of the 50 original benchmark records as validation observations.

## Promotion decision

The candidate rules remain **validation_required** until explicit acceptance thresholds are agreed and the independent validation passes them.

No automatic full-corpus adjudication should occur before that promotion decision.
