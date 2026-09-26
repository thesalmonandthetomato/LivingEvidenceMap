# Workflow 06: ad hoc baseline-establishment actions

This file records non-routine actions used to establish the validated Workflow 06 baseline. These actions are not part of the production methodology.

## 26 September 2026: production merge recovery

The original 20-shard semantic geography production run completed every model-coding shard successfully, but the final merge job failed on the validation expression:

identical(sort(x$record_sequence), seq_len(19407L))

The merged values were complete and unique, but readr had parsed record_sequence as numeric/double while seq_len() returns integer. identical() therefore failed on type despite equivalent values.

The validator was corrected to compare:

sort(as.integer(x$record_sequence))

A recovery workflow downloaded the already completed 20 shard artefacts from production run 36249616391, validated 20 CSV and 20 JSONL shard files, and merged them without making any new model calls.

The recovery/merge run 36265092530 passed and produced the validated 19,407-record Workflow 06 baseline.

## QC-summary interpretation

The recovered merge's legacy summary.json reports deterministic_exact_agreement_n = 16120, calculated directly from the boolean exact_agreement field.

The explicit discrepancy_type classification first prioritises llm_failure and ungrounded_evidence, then labels remaining exact country-set matches as exact_agreement. Consequently:

- discrepancy_type == exact_agreement: 15,953;
- non-exact discrepancy classes: 3,454;
- evidence_all_grounded == FALSE: 239, comprising 235 ungrounded_evidence cases plus 4 model failures.

For reporting and archival QC summaries, discrepancy_type is treated as the authoritative classification. The older boolean aggregate is retained only as provenance.
