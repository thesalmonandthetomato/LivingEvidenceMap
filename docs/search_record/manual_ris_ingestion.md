# Manual RIS ingestion via an existing Zenodo draft

Use this procedure for database searches that must be exported manually as RIS, including searches split across multiple files.

## 1. Run and document the final search

Record:

- database and platform;
- search date;
- exact search string;
- searched fields/scope;
- any limits;
- reported result count.

Export the complete result set as RIS. If the database imposes an export limit, export consecutive chunks without editing or deduplicating them.

## 2. Stage the raw search in Zenodo

1. Create a new Zenodo upload and keep it as a **draft**.
2. Set access to **restricted** where required by database licensing.
3. Upload every raw RIS chunk exactly as exported.
4. Reserve the DOI.
5. Save the draft but do not publish it.

The raw RIS files must not be committed to Git or Git LFS.

## 3. Create the Workflow 00 registry

Create one registry under `user_input/` for the logical search. Follow:

- `config/workflow00_ris_registry.schema.json`
- `user_input/workflow00_ris_registry.example.json`

The registry identifies the database, search, RIS keyword semantics and existing Zenodo draft.

`database.short_name` is the stable source code propagated through the existing W01 `source` field.

The registry may initially leave `input.files` empty. Workflow 00 can discover the RIS files from the existing Zenodo draft. When the draft is completed, the archived `source_registry.json` records every raw filename, byte size and SHA-256 checksum.

## 4. Run operation: validate

Run **Workflow 00 - Manual RIS Zenodo** and select:

- the registry path;
- operation: `validate`.

Validation is read-only. It:

1. authenticates with `ZENODO_ACCESS_TOKEN`;
2. resolves the existing Zenodo draft;
3. discovers the RIS chunks;
4. downloads the raw files;
5. computes byte sizes and SHA-256 checksums;
6. rejects byte-identical duplicated chunks;
7. parses all complete RIS records;
8. derives source-native `source_record_id` values;
9. collapses repeated source IDs only when the complete raw RIS payload is identical;
10. fails on conflicting payloads for the same source ID;
11. combines unique records into one W00 handover JSONL;
12. compares the unique record count with `search.reported_results` when supplied.

No Zenodo files are created, replaced or published during `validate`.

## 5. Run operation: complete

After validation passes, run the same workflow with operation:

`complete`

This repeats the validation and then adds the derived Workflow 00 package to the **same existing Zenodo draft**:

- `source_registry.json`;
- `records.jsonl`;
- `manifest.json`;
- `SHA256SUMS`;
- `chunk_file_checksums.csv`;
- `exact_duplicate_source_record_ids.csv`.

The completed archival registry contains the resolved raw RIS filenames, byte sizes and SHA-256 checksums.

The workflow must never create a new Zenodo deposition for a manual RIS search.

## 6. Run operation: publish

After inspecting the completed draft, run the same workflow with operation:

`publish`

Publication is guarded. Workflow 00:

1. confirms the Zenodo record is still a draft;
2. confirms the DOI matches the registry;
3. requires Zenodo access to be `restricted`;
4. reads the archived `source_registry.json` back from Zenodo;
5. re-downloads every raw RIS file and verifies its byte size and SHA-256;
6. requires the exact expected raw + derived file set;
7. requires every file to have `status=completed`;
8. publishes that same existing draft;
9. verifies the published DOI.

Publication is therefore a separate deliberate operation after validation and completion.

## Outputs and identity

The published restricted Zenodo record is the authoritative Workflow 00 archive for that logical search.

Manual RIS imports use the existing downstream manifestation identity contract:

- `source` = stable database code from `database.short_name`;
- `source_record_id` = source-native record identifier.

Search-run metadata remains in the Workflow 00 registry/archive and is not added as a separate canonical JSON field.

## Later search updates

A later search of the same database is a new logical Workflow 00 search:

1. create a new restricted Zenodo draft;
2. export and upload the new RIS result set;
3. create a new registry;
4. run `validate`;
5. run `complete`;
6. run `publish`.

Workflow 01 will later use the existing `source + source_record_id` identity to recognise database manifestations already known and pass genuinely new records into downstream bibliographic reconciliation.

## GitHub Actions availability

The manual workflow is `.github/workflows/workflow_00_manual_ris_zenodo.yml`. GitHub requires a manually dispatched workflow to be available on the repository's default branch before it appears normally in the Actions interface. Development remains on `workflow01-final-architecture` until deliberately incorporated into `main`.
