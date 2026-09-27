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


## 26 September 2026: four model-failure recoveries

The validated baseline contained four records whose original semantic geography calls failed the W06 structural invariant.

Targeted recovery run 36271055010 reran only those four records with the locked W06 prompt. Three returned valid NONE classifications. The fourth returned an invalid pseudo-country code (ZZZ, "Global/multiple countries") and was rejected.

Targeted recovery run 36271186232 reran only that remaining record with an explicit pseudo-country guard. It returned NONE because the study concerned the global salmon farming industry but did not identify a specific country.

The four validated replacements were then applied only to those four stable record_id values during archival. No other W06 record was changed.

Corrected authoritative counts are:

- RESOLVED: 7,770;
- NONE: 11,166;
- UNRESOLVED: 471;
- model failures: 0;
- evidence not fully grounded: 235;
- exact QC agreement: 15,956;
- QC discrepancies: 3,451.

The corrected state is archived as restricted Zenodo record 22983049, DOI 10.5281/zenodo.22983049.


## 27 September 2026: final W06 validation rules and W08 separation

The W06 evidence validator was broadened to tolerate harmless source-format differences, model-inserted ellipses whose fragments are recoverable in order, and compressed evidence whose normalised words occur in the source in order.

A version-2 W06 prompt was added to reduce future evidence-formatting failures by explicitly instructing the model to copy one continuous source span without dropping words or splicing fragments. The substantive geography definition was not changed.

The final architecture makes the Luna semantic result authoritative for automated geography. The deterministic geography layer is retained for QC and regression monitoring only and does not override Luna.

Human geography decisions made during validation were moved out of W06 into `data/workflow08/geography_adjudication_decisions.jsonl`. W08 is therefore the sole human-adjudication layer for these decisions.

The corrected automated W06 baseline remains Zenodo record 22983049. Human decisions are not written back into that automated checkpoint.
