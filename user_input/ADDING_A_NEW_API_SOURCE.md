# Adding a new API source

Use this guide when adding a new bibliographic database or search platform that can be harvested through an API.

The important design principle is:

> **Write source-specific logic once, at Workflow 00 ingestion. From Workflow 01 onwards, the source should use the generic pipeline.**

A new API should therefore be adapted to the existing Workflow 00 → Workflow 01 handoff rather than adding database-specific logic throughout later workflows.

## What normally needs to change

For a new API source, you should normally need to:

1. add a Workflow 00 harvester/adapter for the API;
2. map the API response into the standard Workflow 00 source-sidecar structure;
3. preserve and archive the raw search response and provenance;
4. give the source a stable provider code and source-native record identifier;
5. register its prepared Workflow 01 input in `config/workflow01_source_catalogue.json`;
6. run the source-identity and W01 validation checks.

You should **not** normally need to change:

- Workflow 01 deduplication thresholds or rules;
- duplicate candidate scoring;
- clustering;
- canonical JSONL construction;
- Workflow 02 enrichment logic;
- Workflow 03 publication-status checks;
- Workflow 04 screening;
- Workflows 05–08 annotation/adjudication;
- Workflow 09 reporting; or
- Workflow 10 dashboard logic.

Those downstream stages are intended to be source-generic.

## 1. Choose a stable source code

Choose a short, permanent provider slug for the database.

Examples:

```text
lens
scopus
openalex
wos
agricola
econlit
```

Rules:

- lower-case;
- begin with a letter or number;
- use only letters, numbers, underscores or hyphens;
- do not encode the search date in the source code;
- do not change the source code between updates of the same database.

Workflow 01 currently accepts provider slugs matching:

```text
^[a-z0-9][a-z0-9_-]*$
```

The stable source code becomes the `source` component of the manifestation identity.

## 2. Identify the source-native record ID

Every harvested record must have a stable identifier supplied by the database itself.

Examples include:

- Scopus EID;
- OpenAlex work ID;
- Web of Science UT;
- a database accession number;
- another persistent record identifier returned by the API.

Do **not** use row number, retrieval order, title hash or a locally generated sequence as the primary source identifier when a source-native identifier exists.

The downstream manifestation identity is:

```text
source + source_record_id
```

That identity is how Workflow 01 recognises records already seen in previous searches of the same database.

## 3. Build the Workflow 00 API harvester

The source-specific code belongs in Workflow 00.

The harvester should:

1. read the authoritative conceptual search strategy from `user_input/workflow00_search_strategy.json` where applicable;
2. translate that strategy into the API's query syntax;
3. apply only source-required field/date restrictions;
4. retrieve all result pages required for the search;
5. retain enough raw API response data to audit the harvest;
6. preserve source-native identifiers;
7. record the exact search date, query and source/platform details;
8. avoid silently dropping fields that may be useful for bibliographic repair or provenance.

The harvester should be written in **R**, consistent with the repository workflow architecture.

Do not place API keys or tokens in the repository. Use GitHub Actions secrets.

## 4. Produce the standard Workflow 00 handoff

The new source must be normalised before Workflow 01.

The prepared JSONL records should expose the same conceptual information already used by existing source adapters, including where available:

- source/provider;
- source-native record ID;
- title;
- abstract;
- DOI;
- authors;
- publication year;
- journal/source title;
- volume;
- issue;
- pages;
- publication type/status;
- ISSN/eISSN/ISSN-L;
- PMID/ISBN where relevant;
- affiliations/institutions;
- author keywords;
- indexing terms;
- source-specific/raw payload.

Not every database will supply every field. Missing values are acceptable. Invented values are not.

The source-specific adapter should preserve raw/source-specific metadata while mapping common bibliographic fields into the standard sidecar structure.

## 5. Preserve provenance and archive the raw search

Workflow 00 is the archival/search layer.

For each API harvest, retain enough information to reconstruct and audit what was searched and retrieved, including:

- database/platform;
- search date;
- exact submitted query;
- field restrictions;
- date restrictions;
- result count reported by the API;
- pagination details where relevant;
- raw or lossless source payloads;
- prepared handoff file;
- checksums;
- manifest/provenance metadata.

Large raw search outputs should be archived in the restricted Zenodo model used by Workflow 00 rather than committed to Git.

Do not commit raw licensed database exports or raw API payloads to the repository unless licensing and repository policy explicitly permit it.

## 6. Add the source to the W01 source catalogue

Once Workflow 00 prepares the source in a stable location, add it to:

`config/workflow01_source_catalogue.json`

For an API source incorporated into the normal Workflow 00 state, use:

```json
"<source>": {
  "kind": "workflow00_state",
  "source": "<source>",
  "prepared_path": "current_sources/<source>/<prepared-file>.jsonl"
}
```

For example:

```json
"econlit": {
  "kind": "workflow00_state",
  "source": "econlit",
  "prepared_path": "current_sources/econlit/econlit_sidecar_records.jsonl"
}
```

The `prepared_path` must match the file created/restored by the Workflow 00 preparation step.

Do not add database-specific deduplication behaviour here. The catalogue only tells W01 which validated prepared sources to ingest.

## 7. Validate source identity before deduplication

Workflow 01 should then validate that:

- every record reports the expected provider/source;
- every record has a non-empty `source_record_id`;
- `source + source_record_id` is stable;
- exact repeated source IDs with identical payloads can be collapsed;
- conflicting payloads under the same source ID cause a failure rather than an arbitrary choice;
- records already known from the previous W01 state are recognised;
- only genuinely new manifestations are promoted into incremental deduplication.

A new source should not require changes to the deduplication thresholds or candidate-scoring rules simply because it comes from a different database.

## 8. Run a small integration test first

Before running the full search result set, test a small sample through the W00 → W01 boundary.

Check that:

- the source code is correct;
- source-native IDs are preserved;
- titles/abstracts/DOIs are mapped correctly;
- authors and publication fields survive;
- provenance fields are retained;
- no field is silently overwritten or lost;
- the W01 source catalogue recognises the new source;
- the generic source-identity filter accepts it;
- the union contains the expected source count.

Only after this passes should the complete harvest be processed.

## 9. Run the full W01 integration

For the first full ingestion of a new source, verify explicitly:

- source manifestation count before deduplication;
- number already known, if any;
- number of newly promoted manifestations;
- incremental duplicate-candidate count;
- deterministic duplicate decisions;
- LLM adjudications, if any;
- human-review cases, if any;
- final canonical-work count;
- source contribution to canonical works;
- successful delta/checkpoint reconstruction.

The W01 run should preserve all prior source manifestations and decisions while adding the new source.

## 10. Future updates of the same API source

Future searches of the same database should reuse:

- the same source code;
- the same source-native identity rule;
- the same field mapping;
- the same W00 adapter.

Only the new harvest/search provenance changes.

Workflow 01 will use `source + source_record_id` to recognise manifestations already present and pass only new manifestations into incremental reconciliation.

## When downstream code really does need changing

A new database should trigger downstream code changes only when it exposes a genuinely new methodological requirement, not merely because it is a new source.

Examples that may justify a deliberate change include:

- the database lacks any stable source-native identifier;
- its API returns records at a different unit of observation from bibliographic works;
- a new field is methodologically important enough to become part of the canonical schema;
- licensing requires a different archival or public-output treatment;
- its search API imposes restrictions that alter the documented search method.

In those cases, update the relevant contract and documentation explicitly rather than adding silent source-specific exceptions.

## Checklist

Before declaring a new API source integrated, confirm:

- [ ] stable source/provider code chosen;
- [ ] stable source-native record ID identified;
- [ ] R-based W00 API harvester implemented;
- [ ] exact search/provenance metadata recorded;
- [ ] raw/lossless source payload archived appropriately;
- [ ] prepared source-sidecar JSONL produced;
- [ ] common bibliographic fields mapped without invention;
- [ ] source-specific metadata preserved;
- [ ] source added to `config/workflow01_source_catalogue.json`;
- [ ] W01 source-identity validation passes;
- [ ] small integration test passes;
- [ ] full source count reconciles;
- [ ] W01 incremental deduplication completes without changing historical decisions;
- [ ] downstream workflows require no source-specific edits unless methodologically justified.

## Related files

- `user_input/workflow00_search_strategy.json`
- `config/workflow01_source_catalogue.json`
- `scripts/updater/workflow_01_prepare_source_catalogue.R`
- `scripts/updater/workflow_01_source_identity_filter.R`
- `docs/search_record/manual_ris_ingestion.md` for databases that must be imported manually rather than harvested through an API.
