# User input

This directory contains user-editable inputs that define the topic-specific behaviour of the Living Evidence Map pipeline.

## Workflow 00 search strategy

`workflow00_search_strategy.json` is the authoritative conceptual search definition for Workflow 00. Workflow code must generate source-specific queries from this file rather than maintaining independent topic-specific search strings in workflow or script files.

The current configuration retains the validated salmon-farming search concepts. Future topic adaptations should replace the user input while leaving the Workflow 00 orchestration and source handlers unchanged.

Other genuinely user-editable pipeline inputs, such as prompts used by downstream workflows, may be moved here later after their interfaces are reviewed.


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
