# Manual RIS ingestion via a Zenodo draft

Use this procedure for database searches that must be exported manually as RIS, including searches split across multiple files.

## Before uploading

1. Run the final database search and record the exact:
   - database and platform;
   - search date;
   - Boolean search string;
   - fields/scope searched where known;
   - limits applied;
   - total number of results reported by the database.
2. Export the complete result set as RIS.
3. If the database limits export size, export consecutive chunks. Do not intentionally deduplicate or modify the RIS files.

## Stage the raw search in Zenodo

1. Create a new Zenodo upload and keep it as a **draft**.
2. Set the intended file visibility to **restricted** where database licensing requires this.
3. Upload every raw RIS chunk exactly as exported.
4. Reserve a DOI if desired.
5. **Save the draft but do not publish it.**
6. Record the reserved DOI and, when available, the Zenodo deposition/draft identifier.

The raw RIS files must not be committed to Git or Git LFS.

## Create the Workflow 00 registry

Create one JSON registry under `user_input/` for the entire logical search, not one registry per chunk. Follow:

- `config/workflow00_ris_registry.schema.json`
- `user_input/workflow00_ris_registry.example.json`

The registry must list every RIS filename under `input.files`. Record `input.expected_chunk_count` and `search.reported_results` whenever known.

`database.short_name` is the stable source code propagated through the existing W01 `source` field. Do not create a separate search-run/source-ID field in the canonical JSON.

## Workflow 00 validation

The R importer must:

1. retrieve all listed RIS files from the Zenodo draft;
2. verify that the supplied filenames exactly match the registry;
3. compute SHA-256 for every chunk;
4. reject byte-identical duplicated chunks;
5. parse every complete RIS record;
6. derive the source-native `source_record_id`;
7. identify repeated native IDs within and across chunks;
8. collapse duplicates only when the complete RIS payload is identical;
9. fail when the same native ID has conflicting payloads;
10. combine unique records into one W00 handover JSONL;
11. compare the unique record count with `search.reported_results`;
12. fail completeness validation when the counts differ.

A failed validation must leave diagnostic checksum/duplicate audit files available for inspection.

## Complete the same Zenodo draft

After validation succeeds, W00 adds the following to the **same draft**:

- all raw RIS chunks already uploaded;
- `source_registry.json`;
- combined `handoff/records.jsonl`;
- `manifest.json`;
- `SHA256SUMS`;
- chunk checksum audit;
- exact-duplicate native-ID audit;
- any conflict audit generated during validation.

Only after all validation checks pass should W00 publish the restricted Zenodo record. The resulting Zenodo record is the authoritative W00 archive for that logical search.

## Updates

A later search of the same database is a new logical W00 search and should use a new Zenodo draft and new registry. W01 uses the existing `source + source_record_id` identity to recognise manifestations already present and passes only genuinely new source records into downstream bibliographic deduplication.

Search-run history remains in the W00 registries and Zenodo archives rather than being propagated as a new field through the canonical JSON.
