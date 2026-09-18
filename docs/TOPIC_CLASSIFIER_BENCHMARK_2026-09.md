# Topic-classifier benchmark, September 2026

## Purpose

Before applying topic classification to the full Living Evidence Map corpus, alternative OpenAI models were benchmarked against a fixed 50-record sample. The aim was not simply to maximise agreement with the historical corpus. The practical criteria were:

1. substantive plausibility of the assigned ontology pathways;
2. restraint, so that contextual mentions and incidental measurements are not promoted to separate topics;
3. reproducibility between independent runs; and
4. continuity with the existing historical topic assignments.

All tests used the original V4 topic-classification instructions, the same 50 records, the LivingEvidenceMap copy of `data/reference/topic_ontology_v3.csv`, structured output, and medium reasoning effort. The historical assignments are treated as a continuity reference, not as a human gold standard.

## Historical reference

The 50-record benchmark sample has a mean of **2.78 historical topic pathways per record**.

The historical full-corpus V4 classifier used `gpt-5-mini`, but the exact dated historical model snapshot is no longer assumed to be available. The current generic model alias can therefore be tested for behavioural similarity, but exact reproduction cannot be assumed.

## Benchmark results

| Model | Pass | Exact agreement with historical | Historical path precision | Historical path recall | Historical path F1 | Mean Jaccard vs historical | Mean topics/record |
|---|---:|---:|---:|---:|---:|---:|---:|
| GPT-5 mini | A | 46% | 0.779 | 0.813 | 0.796 | 0.706 | 2.90 |
| GPT-5 mini | B | 50% | 0.833 | 0.827 | 0.830 | 0.759 | 2.76 |
| GPT-5.6 Luna | A | 36% | 0.825 | 0.612 | 0.702 | 0.618 | 2.06 |
| GPT-5.6 Luna | B | 28% | 0.819 | 0.619 | 0.705 | 0.605 | 2.10 |
| GPT-5 Nano | A | 28% | 0.766 | 0.518 | 0.618 | 0.535 | 1.88 |
| GPT-5 Nano | B | 18% | 0.712 | 0.532 | 0.609 | 0.488 | 2.08 |

The exact Mini and Luna historical-comparison metrics are retained in their benchmark artefacts. The key selection issue was not historical agreement alone, because manual inspection showed that some historical assignments appeared over-inclusive.

## Between-run reproducibility

| Model | Exact self-agreement | Self path precision | Self path recall | Self path F1 | Mean self-Jaccard |
|---|---:|---:|---:|---:|---:|
| **GPT-5.6 Luna** | **64% (32/50)** | — | — | **0.894** | **0.838** |
| GPT-5 mini | 50% (25/50) | — | — | 0.813 | 0.719 |
| GPT-5 Nano | 32% (16/50) | 0.615 | 0.681 | 0.646 | 0.560 |

Luna was therefore substantially more reproducible than Mini and Nano on this benchmark.

## Interpretation

### GPT-5 Nano

Nano was rejected as a production candidate. It showed low self-agreement, low agreement with the historical assignments, and substantial under-coding. Although cheap, the reduction in cost was not considered sufficient to offset the loss of consistency and coverage.

### GPT-5 mini

The current Mini model most closely reproduced the historical coding density and had the highest agreement with the historical assignments. However, its independent passes agreed exactly on only half of the records. This raised concern about run-to-run variability for a living evidence map.

### GPT-5.6 Luna

Luna was more conservative than the historical classifier, averaging about 2.1 topics per record, but was markedly more reproducible. Manual inspection of several Luna/historical disagreements suggested that a meaningful proportion of Luna omissions were defensible applications of the V4 rule that background concepts and measurements used only to evaluate another substantive question should not be coded separately.

At this stage Luna is the leading production candidate, but **no full-corpus Luna classification should be treated as approved until the 50 benchmark records have been manually reviewed for substantive coding sense**. That review should explicitly identify overcoding, undercoding, unstable assignments, and ontology-boundary problems.

## Relevant runs and artefacts

- Historical-replication test with GPT-5 mini: run **35265325928**.
- Mini/Luna two-pass consistency benchmark: run **35267845274**.
- Nano initial benchmark: run **35271447128**.
- Nano recovery run with preserved checkpoint: run **35314806759**.
- Final Nano artefact: **10535835629**.
- Fixed sample seed: **20260917**.
- Nano final run commit: `9991273df34cab7487c431ebe661a00f27e1d6b6`.

## Decision status

**Current status: validation in progress.**

The present evidence rules out Nano and identifies Luna as the strongest candidate on consistency and restraint. A record-level human review of all 50 benchmark records is required before deciding whether to classify the full approximately 16,000-record corpus with Luna.

## Ranked Luna benchmark: primary and secondary pathways

A subsequent two-pass benchmark tested whether each assigned pathway could also be classified as **PRIMARY** or **SECONDARY** without materially reducing reproducibility. The substantive V4 coding rules were left unchanged. The only scientific change was the addition of a pathway role: PRIMARY for a central contribution, and SECONDARY for an independently substantive but non-central contribution. Background concepts and incidental measurements remained excluded rather than being retained as secondary topics. The ontology used for this test also included the newly added `V3_134 Biofouling and net fouling management` pathway.

Run: **35318055832**. Artefact: **10536181345**.

| Measure | Result |
|---|---:|
| Pathway-set exact agreement | **64% (32/50)** |
| Pathway self-Jaccard | **0.807** |
| Pathway self-F1 | **0.868** |
| Exact agreement including PRIMARY/SECONDARY roles | **56% (28/50)** |
| Role agreement on pathways assigned by both passes | **85.4% (70/82)** |
| Exact agreement on PRIMARY pathway sets | **72% (36/50)** |
| Primary-path self-Jaccard | **0.817** |
| Primary-path self-F1 | **0.836** |
| Mean topics per record, pass A / B | **1.90 / 1.88** |
| Mean PRIMARY topics per record, pass A / B | **1.32 / 1.12** |

Adding PRIMARY/SECONDARY did **not reduce exact pathway-set agreement**, which remained at 64%, the same as the earlier unranked Luna benchmark. It produced four records where the two passes selected exactly the same pathways but disagreed only on the role of one pathway. Eighteen additional records differed in pathway inclusion. Thus most disagreement remained about whether a pathway should be assigned at all, rather than about PRIMARY versus SECONDARY status.

The ranked runs were somewhat more conservative than the earlier unranked Luna runs (1.88–1.90 versus 2.06–2.10 topics per record). Agreement with the historical assignments remained deliberately secondary to human substantive review: historical exact agreement was 28% and 30% for the two ranked passes, with path-level F1 of 0.684 and 0.704 respectively.

The PRIMARY/SECONDARY distinction therefore appears feasible, but final adoption remains contingent on human review of the 50-record ranked outputs, especially whether the reduced coding density reflects appropriate exclusion of marginal pathways or excessive under-coding.
