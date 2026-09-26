# Workflow 05: ad hoc baseline-establishment actions

This file records non-routine actions used to establish the validated Workflow 05 baseline. These actions are not part of the production methodology.

## 26 September 2026: species-only architecture correction

During finalisation, legacy Workflow 05 controllers were found to retain older species-assignment and geography/adjudication machinery. The production W05 architecture was rebuilt so that it performs deterministic species coding from titles and abstracts only.

Legacy concepts such as focal/primary/co-primary species are not part of the production W05 definition.

## Vocabulary preservation

The previously validated multilingual species vocabulary, observed spelling variants and text-normalisation behaviour were preserved.

The ambiguous term `spring salmon` was removed after inspection showed that it could act as a descriptive phrase rather than a reliable Chinook salmon synonym.

`Salmons` and `salmones` were retained/added under `Unspecified species`.

## Three-column schema migration

The runtime vocabulary was migrated from the older repository-specific multi-column species dictionary to the requested generic schema:

`coding, entity, terms`

The first three-column run passed structurally but changed 13 record-level codings because the adapter initially discarded term-type information used internally for validated plural and OCR-spacing behaviour.

The adapter was corrected to infer the required matcher behaviour deterministically from the three-column terms without adding columns to the runtime vocabulary.

Final run `36268840588` was then compared record-by-record against the preceding validated rebuilt run `36266979542`:

- records compared: 19,407;
- coding differences: 0.

This comparison establishes that the schema migration preserved the validated species results exactly.
