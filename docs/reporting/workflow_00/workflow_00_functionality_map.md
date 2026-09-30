# Workflow 00: Search orchestration, provenance and archival

## Purpose

Workflow 00 manages reproducible literature searching across the supported bibliographic sources. It converts a single version-controlled search strategy into source-specific queries, executes each selected source independently, records the exact searches performed, and preserves both lightweight provenance in the repository and durable search outputs in Zenodo.

This document is intended to serve two purposes:

1. as a methodological guide to the repository implementation; and
2. as source text for reporting the search workflow in a research paper.

## Functionality map

Functionally, Workflow 00 comprises one parent orchestrator plus one reusable source handler. The parent launches the handler independently for Lens, Scopus, OpenAlex, AGRICOLA and Web of Science. The handler then invokes the appropriate source-specific R ingestion code.

```text
user_input/workflow00_search_strategy.json
          |
          v
workflow_00_search_orchestrator.yml
  |
  |-- validate strategy + construct database-specific search strings
  |
  |-- Lens ------|
  |-- Scopus ----|
  |-- OpenAlex --|--> _workflow_00_orchestrated_source_child.yml
  |-- AGRICOLA --|          |
  |-- WoS -------|          '--> source-specific R ingestion
  |
  |-- optional expansion reconciliation by native source ID
  |
  |-- archive search documentation in repository
  |
  '-- archive complete search run to restricted Zenodo record
                              |
                              v
                    Workflow 01 input
```

## Components

| Component | Function |
|---|---|
| `user_input/workflow00_search_strategy.json` | Authoritative search concept definition. Stores the search version, immutable species terms and farm/aquaculture terms. |
| `scripts/updater/workflow_00_search_orchestrator.R` | Translates the common strategy into syntax appropriate for each source and defines full, fortnightly and expansion searches. |
| `.github/workflows/workflow_00_search_orchestrator.yml` | Parent controller. Selects sources, creates the search plan, launches source jobs, checks completion, archives documentation and deposits the completed run on Zenodo. |
| `.github/workflows/_workflow_00_orchestrated_source_child.yml` | Reusable source handler called once for each selected database. |
| Source-specific R ingestion scripts | Execute the individual API/database searches and produce source-native harvests and manifests. |
| `scripts/updater/write_workflow00_search_record.R` | Produces machine-readable JSON and human-readable Markdown records for every source search. |
| Workflow 00 Zenodo archiver | Packages the complete parent search run and creates one restricted Zenodo record per Workflow 00 run. |

## Search strategy and search strings

The conceptual search strategy is permanently version-controlled in:

`user_input/workflow00_search_strategy.json`

For search version `v1`, the common species block is:

```text
salmon
salmonid*
Salmo
Oncorhynchus
"rainbow trout"
```

The farm/aquaculture block is:

```text
farm*
cage*
pens
penned
pen
aquacultur*
commercial*
```

The database-specific search strings are generated programmatically from this common configuration. This avoids maintaining independent manually edited search strings for each source.

The exact queries actually executed are recorded at two levels:

- `search_plan.json` and `source_queries.json` record the database-specific queries generated for the parent run; and
- each source produces a JSON and Markdown search record under `docs/search_record/`, containing the exact query actually executed together with the search date, source, result counts and workflow provenance.

The repository therefore preserves both the rule used to generate each query and the exact query executed in each search.

## Run modes

Workflow 00 supports three run modes.

### Full

A complete search of the selected sources using the current version-controlled search strategy.

### Fortnightly

A source-specific update search intended to identify newly indexed records while retaining the same underlying search concepts. Date or indexing filters are applied only where their semantics have been explicitly implemented for the source.

Every fortnightly harvest is then reconciled against that source's persistent native-ID registry before Workflow 01. This is an exact source-level delta filter, not bibliographic deduplication. Lens uses Lens ID; Scopus uses EID; OpenAlex uses Work ID; AGRICOLA uses the Europe PMC AGR source plus ID; and Web of Science uses UID. Already-known native IDs remain preserved in the raw search archive but are not passed downstream. Only previously unseen native IDs are emitted in the filtered source-shaped harvest consumed by Workflow 01. The updated source-native ID registry is committed only after the selected source jobs have completed successfully.

The five sources do not expose equivalent update-date semantics, so Workflow 00 records the retrieval mechanism explicitly rather than presenting the searches as methodologically identical:

| Source | Fortnightly retrieval mechanism | Search fields | Important constraint |
|---|---|---|---|
| Lens | `created` date, 14-day window | title, abstract, keyword | Uses Lens creation/indexing metadata. |
| Scopus | `ORIG-LOAD-DATE` after the 14-day boundary | title, abstract, keywords | Uses Scopus load-date metadata. |
| OpenAlex | current publication year plus following publication year | title and abstract only | Deliberate workaround: the workflow does not use the relevant paid date filtering, and title/abstract-only search prevents full-text searching. Previously harvested Work IDs are removed after retrieval. |
| AGRICOLA | `FIRST_PDATE` 14-day window via Europe PMC, restricted to `SRC:AGR` | title and abstract | Provider/API constraint: this is a first-publication-date filter rather than a true indexing-date filter. Previously harvested AGR IDs are removed after retrieval. |
| Web of Science | Starter API `modifiedTimeSpan`, 14-day window | title, abstract, author keywords | The update window is supplied as a separate API parameter rather than embedded in the query string. |

These source-specific rules are written into each fortnightly `search_plan.json` under `source_update_methods`.

### Expansion

A controlled search-term expansion. The species block is immutable. A new farm/aquaculture term may be added and searched while excluding the existing farm-term block. Retrieved records are reconciled against persistent native source identifiers before downstream bibliographic deduplication.

## Provenance and search documentation

Each source search produces a structured provenance record containing, where applicable:

- source;
- run type;
- search-strategy version;
- exact search string;
- date and time of execution;
- number of results reported by the source;
- number of records successfully downloaded;
- whether the download was complete;
- parent and child GitHub workflow run identifiers;
- Git commit/ref provenance;
- associated harvest artefact;
- for fortnightly searches, the number of already-known native IDs and genuinely new native IDs passed downstream;
- additional search term for expansion searches.

The same information is written in both JSON and Markdown formats.

## Storage and archival model

### Permanent repository records

The GitHub repository stores lightweight, inspectable methodological and provenance records:

- search strategy configuration and R implementation;
- per-source JSON and Markdown search records;
- expansion reconciliation documentation, where applicable;
- persistent native source-ID registries used for expansion reconciliation;
- `docs/search_record/zenodo_registry.csv`;
- one small JSON pointer for each archived Workflow 00 run containing the corresponding Zenodo record, DOI and checksums;
- `docs/search_record/state/current.json`, the authoritative logical five-source Workflow 00 state consumed by Workflow 01; and
- immutable historical state snapshots such as `docs/search_record/state/baseline-v1.json`.

### GitHub Actions artefacts

Validated handoff/documentation artefacts such as search plans, search-record bundles, expansion reconciliation outputs and Zenodo receipts are normally retained for seven days.

Raw source-harvest artefacts are also recovery checkpoints for potentially costly database/API retrieval and are therefore retained for at least 90 days under the repository checkpoint policy. Workflow 01 may use a live source-harvest artefact as a fast handoff only when it can verify the artefact against the registered Workflow 00 handoff checksum.

Actions artefacts are not the durable source of truth; the registered restricted Zenodo search archive remains authoritative.

### Durable Zenodo archive

Each completed parent Workflow 00 search run is preserved as a single restricted Zenodo record.

The record contains:

- one compressed harvest archive for each source included in the run;
- a compressed search-documentation archive containing the search plan and per-source search records;
- expansion reconciliation material where applicable;
- a machine-readable manifest containing filenames, byte sizes and SHA-256 checksums.

Zenodo metadata remain discoverable while the archived search-result files are restricted. The repository stores the DOI and record identifier so downstream workflows can retrieve the exact archived inputs deterministically.

## Validated-state handoff

Workflow 00 follows the repository-wide validated-state handoff policy. Validated source harvest artefacts are retained in GitHub Actions for seven days as a fast downstream cache. The corresponding restricted Zenodo record remains authoritative. Workflow 01 may use the Actions harvest only when its source/run identity and registered handoff checksum match the authoritative Workflow 00 pointer; otherwise it restores the same source state from Zenodo.

The cache and Zenodo routes are delivery mechanisms for the same accepted state, not separate sources of truth.

## Downstream handoff

Workflow 01 consumes one authoritative Workflow 00 state pointer. The state identifies the accepted Lens, Scopus, OpenAlex, AGRICOLA and Web of Science source archives and their source-specific checksums. Downloads are authenticated and verified against the stored byte sizes and SHA-256 checksums before extraction. The initial five-source baseline is a composite state referencing three immutable restricted Zenodo records; no archived search data are duplicated merely to create the logical state. This removes any dependency on long-lived GitHub Actions artefacts.

Workflow 00 remains the authoritative raw-source layer. Raw API/source payloads are preserved in the restricted W00 archives rather than copied wholesale into W01. The W00→W01 adapter layer exposes validated mapped metadata needed for reconciliation and bibliographic preservation. W01 now retains this information additively in source manifestations and promotes validated bibliographic fields such as genuine author keywords, publication type/date, language and supported identifiers to the canonical work object with explicit provenance. These additional fields do not participate in W01 deduplication.

## Methods text for research reporting

> **Workflow 00: literature searching and provenance.** Searches were managed by a reproducible R-based orchestration workflow. A version-controlled configuration defined a common species concept and aquaculture/farming concept, from which database-specific queries were generated for Lens, Scopus, OpenAlex, AGRICOLA and Web of Science. The parent workflow executed each selected source independently through a reusable source handler and source-specific ingestion script. For every search, the exact query, execution date, database-reported result count, successfully downloaded record count and workflow provenance were recorded in machine-readable JSON and human-readable Markdown files. Full searches, fortnightly updates and controlled search-term expansions used the same strategy definition. Search outputs were retained as short-lived GitHub Actions artefacts for seven days and deposited durably as restricted, checksum-verified Zenodo records, with persistent DOI and provenance pointers maintained in the repository.

## Reporting status

Workflow 00 state integrity is validated by `scripts/updater/workflow_00_validate_state.R`, which requires exactly the five expected sources, valid archive references and harvest checksums, and non-empty duplicate-free source-native ID registries. Source-native ID reconciliation is now consistently enforced for fortnightly updates across all five sources. Automatic replacement of a complete source entry in `current.json` by a fortnightly archive nevertheless remains disabled because a fortnightly archive is a delta, not a complete source snapshot. The logical state model must therefore preserve the baseline plus accepted source-level deltas rather than treating the newest delta archive as the whole source.

Workflow 00 is considered complete when:

- the search strategy is version-controlled;
- selected source searches complete successfully;
- per-source search documentation is generated;
- the complete parent search run is deposited on Zenodo;
- the Zenodo DOI, record identifier and manifest checksum are registered in the repository; and
- downstream restoration of the archived source inputs has been validated.

## Independent search scoping stage

Workflow 00 includes a standalone count-only search scoping workflow at `.github/workflows/workflow_00_search_scoping.yml`. It is manually dispatched and is not part of the production harvesting or fortnightly update chain.

The scoping stage uses the same `user_input/workflow00_search_strategy.json` and the same source-specific query planner as production W00, then requests only the provider-reported result count for each implemented API source: Lens, Scopus, OpenAlex, AGRICOLA and Web of Science Core Collection. API responses are held only in memory long enough to extract the total; bibliographic result records and raw API responses are not written to disk.

CAB Abstracts and ProQuest Dissertations & Theses Global remain manual-ingest sources and are reported as not automatically counted because W00 has no API implementation for them.

Outputs are limited to:

- `search_scope_counts.csv`;
- `search_scope_counts.json`;
- `search_scoping_report.Rmd`; and
- rendered `search_scoping_report.html`.

The report records the search version, search concepts, source, date, hit count and source status. The same count table is also written to the GitHub Actions job summary. The scoping workflow does not update source-ID registries, publish to Zenodo, create harvest artefacts, or trigger Workflow 01.
