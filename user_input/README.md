# User input

This directory contains user-editable inputs that define the topic-specific behaviour of the Living Evidence Map pipeline.

## Workflow 00 search strategy

`workflow00_search_strategy.json` is the authoritative conceptual search definition for Workflow 00. Workflow code must generate source-specific queries from this file rather than maintaining independent topic-specific search strings in workflow or script files.

The current configuration retains the validated salmon-farming search concepts. Future topic adaptations should replace the user input while leaving the Workflow 00 orchestration and source handlers unchanged.

Other genuinely user-editable pipeline inputs, such as prompts used by downstream workflows, may be moved here later after their interfaces are reviewed.

## Adding a new API source

For a human-readable guide to adding a new bibliographic API while preserving the generic downstream architecture, see:

`user_input/ADDING_A_NEW_API_SOURCE.md`

The intended pattern is source-specific harvesting and normalisation in Workflow 00, followed by the generic Workflow 01+ pipeline.

## Workflow 00 generic RIS imports

A manually exported RIS search is treated as one logical Workflow 00 source package, even when the database requires the export to be split into multiple files.

The search registry lists every RIS chunk under `input.files` and may record `input.expected_chunk_count` and `search.reported_results`. The R importer:

- requires the supplied filenames to match the registry;
- computes SHA-256 for every raw RIS chunk before parsing;
- rejects byte-identical duplicated chunks and writes a checksum audit;
- parses every chunk and compares source-native record identifiers;
- collapses repeated source records only when the raw RIS payload is identical;
- rejects repeated source identifiers with conflicting payloads;
- combines the unique records into one W00 handover JSONL;
- fails completeness validation when `search.reported_results` is supplied and does not equal the unique handover record count.

The W00 archive for the logical search should retain all raw RIS chunks, the registry, the combined handover JSONL, the manifest, checksum file and duplicate audits together in one restricted Zenodo record.

RIS imports use the existing downstream manifestation identity contract: `source` is the stable database code from `database.short_name`, and `source_record_id` is derived from the source-native record identifier. Search-run metadata remains in the W00 registry/archive and is not added as a new canonical JSON field.

For the complete manual upload procedure using a Zenodo draft, see `docs/search_record/manual_ris_ingestion.md`.

The permanent GitHub Actions entry point is `.github/workflows/workflow_00_manual_ris_zenodo.yml`. It exposes three explicit operations:

- `validate`: read-only discovery, parsing, deduplication and count validation;
- `complete`: repeat validation, resolve raw-file SHA-256 fingerprints and add the derived W00 package to the same existing Zenodo draft;
- `publish`: reverify the archived raw files and exact file set, require restricted access, then publish that same record.

Manual RIS processing is R-only. Raw RIS files are staged in Zenodo and must not be committed to the repository.
