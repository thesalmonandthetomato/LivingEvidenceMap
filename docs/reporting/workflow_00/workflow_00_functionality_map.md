# Workflow 00: Search orchestration, provenance and archival

## Purpose

Workflow 00 manages reproducible literature searching across the supported bibliographic sources. It converts a single version-controlled search strategy into source-specific queries, executes each selected source independently, records the exact searches performed, and preserves both lightweight provenance in the repository and durable search outputs in Zenodo.

This document is intended to serve two purposes:

1. as a methodological guide to the repository implementation; and
2. as source text for reporting the search workflow in a research paper.

## Functionality map

Functionally, Workflow 00 comprises one parent orchestrator plus one reusable source handler. The parent launches the handler independently for Lens, Scopus, OpenAlex, AGRICOLA and Web of Science. The handler then invokes the appropriate source-specific R ingestion code.

```text
config/workflow00_search_strategy.json
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
| `config/workflow00_search_strategy.json` | Authoritative search concept definition. Stores the search version, immutable species terms and farm/aquaculture terms. |
| `scripts/updater/workflow_00_search_orchestrator.R` | Translates the common strategy into syntax appropriate for each source and defines full, fortnightly and expansion searches. |
| `.github/workflows/workflow_00_search_orchestrator.yml` | Parent controller. Selects sources, creates the search plan, launches source jobs, checks completion, archives documentation and deposits the completed run on Zenodo. |
| `.github/workflows/_workflow_00_orchestrated_source_child.yml` | Reusable source handler called once for each selected database. |
| Source-specific R ingestion scripts | Execute the individual API/database searches and produce source-native harvests and manifests. |
| `scripts/updater/write_workflow00_search_record.R` | Produces machine-readable JSON and human-readable Markdown records for every source search. |
| Workflow 00 Zenodo archiver | Packages the complete parent search run and creates one restricted Zenodo record per Workflow 00 run. |

## Search strategy and search strings

The conceptual search strategy is permanently version-controlled in:

`config/workflow00_search_strategy.json`

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
- one small JSON pointer for each archived Workflow 00 run containing the corresponding Zenodo record, DOI and checksums.

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

Workflow 01 retrieves Workflow 00 inputs from the Zenodo records registered in the repository. Downloads are authenticated and verified against the stored byte sizes and checksums before extraction. This removes any dependency on long-lived GitHub Actions artefacts.

## Methods text for research reporting

> **Workflow 00: literature searching and provenance.** Searches were managed by a reproducible R-based orchestration workflow. A version-controlled configuration defined a common species concept and aquaculture/farming concept, from which database-specific queries were generated for Lens, Scopus, OpenAlex, AGRICOLA and Web of Science. The parent workflow executed each selected source independently through a reusable source handler and source-specific ingestion script. For every search, the exact query, execution date, database-reported result count, successfully downloaded record count and workflow provenance were recorded in machine-readable JSON and human-readable Markdown files. Full searches, fortnightly updates and controlled search-term expansions used the same strategy definition. Search outputs were retained as short-lived GitHub Actions artefacts for seven days and deposited durably as restricted, checksum-verified Zenodo records, with persistent DOI and provenance pointers maintained in the repository.

## Reporting status

Workflow 00 is considered complete when:

- the search strategy is version-controlled;
- selected source searches complete successfully;
- per-source search documentation is generated;
- the complete parent search run is deposited on Zenodo;
- the Zenodo DOI, record identifier and manifest checksum are registered in the repository; and
- downstream restoration of the archived source inputs has been validated.
