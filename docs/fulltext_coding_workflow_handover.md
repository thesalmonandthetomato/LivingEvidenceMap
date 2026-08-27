# LivingEvidenceMap — Full-text coding workflow handover

**Snapshot:** 2026-08-27  
**Repository:** `thesalmonandthetomato/LivingEvidenceMap`  
**Purpose:** canonical human-readable handover for resuming full-text coding after the OpenAlex/Zenodo acquisition period.

## Read this first

The **current coding prompt is authoritative** for substantive coding decisions. If this handover, the decision log, older prompts, old schema material, or historical discussion conflicts with the current prompt/schema, use the current prompt/schema and do not resurrect legacy fields or semantics.

Authoritative materials:

- `scripts/fulltext_coding/fulltext_coding_prompt_v3.txt`
- `scripts/fulltext_coding/coding_schema_v3.json`
- `scripts/fulltext_coding/validate_coding_output_v4.py`
- `scripts/fulltext_coding/preflight_coding_schema_v4.py`
- `scripts/fulltext_coding/prepare_fulltext_for_coding.py`
- `scripts/fulltext_coding/code_fulltext_test_v3.py`
- `data/reference/topic_ontology_v3.csv`
- `data/reference/fulltext_batch_registry.csv`

## Current substantive coding rules

- Eligible species are the salmonids defined by the current prompt. When eligible and ineligible species/components coexist, code population, setting, location, facility, system, production stage, life stage, exposure/intervention, comparator, outcomes and funding for the **eligible component only**. `other_farmed_species` may record other species but must not contaminate the focal coding.
- `exposure_intervention` is one combined field. Do not resurrect separate exposure/intervention fields.
- `comparator` is the genuine focal comparator. Do not force survivor-versus-mortality or other incidental contrasts into it.
- `production_stage` and `fish_life_stage` are independent. **Harvest is not a fish life stage.** Adult grow-out is a valid production stage.
- If fish life stage is not explicit, infer **only Juvenile or Adult** when suitable age/mass/development evidence matches the species-specific farmed growth trajectory. Do not infer other life stages from age/mass. Otherwise use `NOT FOUND`.
- Research question and objectives are mandatory retrieval targets. Search the whole document; they do not have to come from the abstract or Introduction.
- Study-design labels are only the current controlled vocabulary and their definitions in the authoritative prompt: `BA`, `CI`, `BACI`, `RCT`, `Time-series`, `Modelling`, `Qualitative`, `not_stated`, `not_applicable`.
- All substantive fields must be present and correctly typed. Array-valued fields must always be arrays. If applicable but genuinely unsupported after active searching, use `["NOT FOUND"]`; do not leave substantive array fields blank.
- `NOT FOUND` and `NULL` should not be overinterpreted semantically beyond the schema requirements; post-hoc consolidation is acceptable where appropriate.
- Evidence must be source-derived article text/context for the exact field/value and must concern the eligible study/component.
- `multiple_studies_flag` requires strong evidence of independently structured eligible studies/components; treatments, time points, assays or outcomes alone do not qualify.
- Ontology values must come only from `topic_ontology_v3.csv`. For reporting, ontology codes are converted using the exact repository hierarchy with ` > ` separators; do not fabricate mappings.

## What we learned from the first 20 studies

The first 20-study run was broadly usable substantively, but it was generated **before the final completeness/NOT FOUND prompt tightening**. Therefore its completeness warnings are not a valid test of the final prompt. Do not retune the prompt merely to make that historical run cleaner.

The review also established that apparent model interpretation in evidence/coding is not inherently a problem when it is functioning as intended by the prompt; only systematic, demonstrable errors should trigger prompt changes.

## Full-text acquisition

The OpenAlex downloader is scheduled separately and produces GROBID TEI/XML. The current acquisition plan is one batch of up to 100 OpenAlex content files per day, with batches 6–40 planned. Full-text batch provenance is recorded in `data/reference/fulltext_batch_registry.csv`.

The registry links:

`DOI → OpenAlex ID → workflow run → Zenodo record → Zenodo version/concept DOI → archive filename → status`

Do not rely on an archive filename alone when registry provenance is available.

## Zenodo → coding architecture

We deliberately chose **one Zenodo record as the processing unit**, not a giant intermediate corpus.

The manual coding workflow is:

```text
Zenodo record
  → archive
  → GROBID TEI/XML files
  → OpenAlex ID / DOI / master CSV match
  → prepare_fulltext_for_coding.py
  → current v3 coding prompt + schema + ontology
  → validation
  → cumulative coding JSON + provenance architecture
```

The workflow is intentionally **manual-dispatch only**. It must not be automatically scheduled. The user decides when to start it and can stop/cancel it.

Current workflow:

`.github/workflows/zenodo_fulltext_ai_coding.yml`

### Processing behaviour

- If no Zenodo record ID is supplied, select the first deposited record with uncompleted records in `fulltext_batch_registry.csv`.
- A specific Zenodo record can be supplied manually.
- Match TEI filenames to OpenAlex IDs and then carry DOI and Zenodo provenance through the coding output.
- Do not send unregistered/unmatched files to the model.
- Skip records already marked completed in the cumulative architecture.
- Code **one paper at a time**.
- After every individual paper, update the cumulative files and commit/push the checkpoint to GitHub before proceeding.
- The workflow may continue through the available deposited records until the user stops it.
- A concurrency lock prevents overlapping coding runs.
- Current GitHub Actions checkpoint artifacts are retained for **90 days**.

## Persistent outputs

### `data/fulltext_coding/cumulative_coding.json`

The cumulative machine-readable archive of actual model annotations. It must grow incrementally as papers are coded.

### `data/fulltext_coding/coding_architecture.json`

The lightweight provenance/index architecture. Each record should clearly connect:

`zenodo_record_id → zenodo_archive_filename → zenodo_source_filename → openalex_id → doi → master_csv_match → coding_run_id`

This architecture is the primary audit trail for knowing exactly where every coded record came from.

## Validation and checkpointing

Validation warnings are diagnostic/non-fatal in the current test workflow. A warning is not automatically a failed coding run.

The important durability boundary is **every individual paper**. The workflow must not wait until a 10-paper or 100-paper block has completed before writing persistent state.

GitHub Actions artifacts are an additional 90-day recovery mechanism, but the cumulative JSON files committed to the repository are the durable project record.

## Matching strategy for the master CSV

Primary key: exact OpenAlex ID.  
Secondary verification: exact DOI after conservative normalisation.  
Title: audit fallback only, never the primary automatic join.

Before a model call, the pipeline should be able to identify:

- Zenodo record ID
- Zenodo archive filename
- Zenodo source filename
- OpenAlex ID
- DOI
- master CSV match
- coding run ID

Unmatched, duplicate or conflicting records should be reported rather than silently coded.

## What to do when resuming

1. Read this file.
2. Read `docs/fulltext_coding_workflow_handover.json`.
3. Read `docs/fulltext_coding_decision_log.md`.
4. Inspect the current authoritative prompt/schema/validator/ontology in the repository; do not rely on an old copy from memory.
5. Check `fulltext_batch_registry.csv` for the deposited Zenodo records and their status.
6. Check `data/fulltext_coding/coding_architecture.json` to determine what has already been coded.
7. Do **not** change the prompt unless a properly generated pilot demonstrates a genuine systematic substantive problem.
8. If the acquisition period is complete, manually dispatch `zenodo_fulltext_ai_coding.yml`.
9. Pilot across more than one Zenodo record before allowing the process to run through the entire deposited corpus.
10. Review completeness/correctness against full text after bulk coding.

## Deliberately not done

- No scheduled automatic AI-coding run.
- No giant local full-text corpus is required for the coding stage.
- No re-run of the historical 20-study baseline is required solely because of its pre-final-prompt completeness warnings.
- No legacy schema fields should be restored.
- No further prompt tuning is required merely because the historical run contained warnings.

## Conversation/decision record

The detailed decisions are maintained in `docs/fulltext_coding_decision_log.md`. The purpose of that file is to preserve **decisions and their rationale**, not to reproduce the raw ChatGPT transcript. The current prompt remains authoritative over historical discussion.
