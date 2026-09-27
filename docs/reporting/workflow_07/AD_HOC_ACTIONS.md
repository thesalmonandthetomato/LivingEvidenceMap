# Workflow 07: ad hoc actions and baseline-establishment record

This file records non-routine analyses used to establish or validate the Workflow 07 production rules. These actions are not themselves part of the permanent production methodology unless explicitly incorporated into `.github/workflows/workflow_07_topic_coding.yml`.

## Historical-topic recall audit

Run **36252255299** compared the current 19,407-record retained population with previously generated three-pass topic results.

It identified:

- 12,297 records with reusable historical three-pass coding;
- 7,110 records requiring fresh classification.

This allowed the baseline to be completed without paying to regenerate already validated model outputs.

## Fresh three-pass production recovery

The final successful production run was **36264955447**. It recovered already submitted/completed Batch API chunks from earlier failed attempts rather than resubmitting them.

The final handoff contained:

- 19,407 record summaries;
- 54,720 unique record-pathway assignments;
- 7,828 one-star assignments;
- 6,963 two-star assignments;
- 39,929 three-star assignments;
- 358 zero-topic records;
- 51 records with more than ten raw topic assignments.

No rerun of the 21,330 fresh model classifications was required after the validated handoff was produced.

## Manual review of high-topic records

A development sample of records with more than ten raw topic assignments was inspected manually to test candidate retention rules.

This review supported a deterministic rule that:

- preserves all raw assignments;
- suppresses documented general/fallback codes only from the analytical layer;
- retains complete star-support tiers in descending order;
- uses a soft maximum of ten;
- retains the full highest tier if that tier alone exceeds ten;
- never breaks equal-support ties arbitrarily.

After this rule was accepted, the remaining high-topic records were no longer treated as automatic human-review cases.

One record encountered during QC was identified as a late relevance exclusion. Such decisions are represented downstream rather than rewriting the historical Workflow 04 layer.

## Zero-topic deterministic lexical diagnostic

Run **36304195833** tested the 358 zero-topic records against ontology lexical cues.

The diagnostic split was:

- 40 no ontology cues;
- 218 weak or ambiguous cues;
- 100 clear candidate pathways under the diagnostic lexical rule.

Random manual inspection showed that these groups mixed genuine zero-topic records, sparse metadata, possible relevance-screening errors and genuine topic-coding misses. The lexical grouping was therefore **not adopted as a production eligibility decision rule**.

The diagnostic workflow is retained for provenance only.

## Zero-topic targeted eligibility rescreen

A more appropriate QC test was then developed: re-screen the zero-topic records directly for evidence of substantive linkage to eligible commercial salmon/rainbow-trout farming.

Run **36304758204** applied two independent Luna eligibility passes to all 358 zero-topic records, with a third pass only where required.

The merged decisions were:

- 217 include;
- 123 exclude;
- 18 uncertain.

Following methodological review, the permanent routing policy was set to:

- include -> retain as included but uncoded;
- exclude -> late automatic exclusion;
- uncertain -> Workflow 08 human adjudication.

The rescreen is now integrated into the main W07 workflow before final Workflow 08 flagging.

## Disagreement-threshold development

Three-pass topic disagreement was measured using mean pairwise Jaccard similarity across the topic sets returned by passes A, B and C.

An earlier broader candidate-review rule produced an unnecessarily large review queue. The final threshold was restricted to:

`mean pairwise Jaccard < 0.20`

The current baseline contains 103 records below this threshold.

High topic count and absence of unanimous topics are not standalone human-review triggers.

## Finalisation validation

A dedicated cheap validation workflow, `.github/workflows/workflow07_finalisation_validation.yml`, was added so changes to downstream W07 routing can be tested against the preserved production topic handoff and zero-topic rescreen without repeating expensive model classification.

The validator asserts the current baseline counts:

- 19,407 records;
- 358 zero-topic records;
- 217 zero-topic includes;
- 123 zero-topic late automatic exclusions;
- 18 zero-topic uncertain;
- 103 extreme-disagreement records;
- 121 total W07 human-adjudication records.

