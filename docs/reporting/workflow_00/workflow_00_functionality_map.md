# Workflow 00: Search orchestration, provenance and archival

## Purpose

Workflow 00 manages reproducible literature searching across the supported bibliographic sources. It contains two deliberately separate pathways: (1) an independent count-only search-scoping stage for testing a manually supplied Boolean search string without harvesting records, and (2) the production search-orchestration pathway that converts the version-controlled production strategy into source-specific queries, retrieves records, records provenance, and archives accepted search outputs.

This document is intended to serve two purposes:

1. as a methodological guide to the repository implementation; and
2. as source text for reporting the search workflow in a research paper.

## Functionality map

Functionally, Workflow 00 has an independent scoping pathway and a production harvesting pathway. The scoping pathway is manually dispatched and never feeds Workflow 01. The production pathway comprises one parent orchestrator plus one reusable source handler; the parent launches the handler independently for Lens, Scopus, OpenAlex, AGRICOLA, PubMed/MEDLINE, EThOS, Chinese Biological Abstracts, Europe PMC preprints and Web of Science, and the handler invokes the appropriate source-specific R ingestion code.

```text
INDEPENDENT SEARCH SCOPING
--------------------------
user_input/scoping_search_string.txt
          |
          v
workflow_00_search_scoping.yml
          |
          |-- validate Boolean syntax before any API call
          |-- translate one database-neutral expression to source syntax
          |-- request counts only from Lens / Scopus / OpenAlex / AGRICOLA / WoS
          |-- retain no bibliographic records or raw API responses
          '-- render CSV + JSON + Rmd + HTML scoping report
          
          [no W01 handoff, no Zenodo, no production-state mutation]


PRODUCTION SEARCHING
--------------------
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
  |-- AGRICOLA -----------|
  |-- PubMed/MEDLINE ------|
  |-- EThOS ---------------|
  |-- Chinese Biol. Abs. --|--> _workflow_00_orchestrated_source_child.yml
  |-- Europe PMC preprints-|          |
  |-- WoS -----------------|          '--> source-specific R ingestion
  |
  |-- optional expansion reconciliation by native source ID
  |-- archive search documentation in repository
  '-- archive complete search run to restricted Zenodo record
                              |
                              v
                    Workflow 01 input
```

## Components

| Component | Function |
|---|---|
| `user_input/scoping_search_string.txt` | Manually editable, database-neutral Boolean search string used only by the independent scoping stage. |
| `scripts/updater/workflow_00_validate_scoping_search.R` | Validates the scoping string before any API call and translates the validated expression into source-specific field syntax. |
| `scripts/updater/workflow_00_search_scope_counts.R` | Performs count-only API requests for Lens, Scopus, OpenAlex, AGRICOLA and Web of Science and writes the count metadata. |
| `.github/workflows/workflow_00_search_scoping.yml` | Standalone manually dispatched scoping controller. It validates, counts, renders the report and uploads only count/report artefacts. |
| `docs/reporting/workflow_00/search_scoping_report.Rmd` | Short R Markdown template for the scoping search string, date, source status and reported hit counts. |
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

Workflow 00 production supports three run modes. In addition, W00 provides a separate count-only scoping mode that is intentionally outside the production chain.

### Search scoping

Search scoping is a manually dispatched, count-only stage for testing a Boolean search string before deciding whether to run a full production search.

The editable input is:

`user_input/scoping_search_string.txt`

The accepted input is a database-neutral Boolean expression using:

- `AND`, `OR`, and `NOT`;
- parentheses;
- straight double quotes for phrases; and
- `*` wildcards.

Before any API request, the validator requires balanced parentheses and quotes, valid Boolean grammar, no missing or dangling operators, no empty groups or quoted phrases, and no database-specific field codes such as `TITLE=`, `TS=`, or `TITLE-ABS-KEY(...)`. Invalid syntax causes the workflow to fail immediately.

After validation, the expression is translated into the current source-specific field scopes and a count-only request is made to each API-backed W00 source. Only the provider-reported result total is retained.

To trigger a scoping run:

1. edit `user_input/scoping_search_string.txt` on `workflow01-final-architecture`;
2. open **Actions** in GitHub;
3. select **Workflow 00 - Count-only search scoping**;
4. click **Run workflow**;
5. select branch `workflow01-final-architecture`;
6. leave the default input path as `user_input/scoping_search_string.txt` unless testing another version-controlled text file; and
7. run the workflow.

The GitHub Actions job summary displays the count table directly. The downloadable artefact contains the validated search plan, CSV and JSON count tables, the R Markdown source and the rendered HTML report.

### Full

A complete search of the selected sources using the current version-controlled search strategy.

### Fortnightly

A source-specific update search intended to identify newly indexed records while retaining the same underlying search concepts. Date or indexing filters are applied only where their semantics have been explicitly implemented for the source.

Every fortnightly harvest is then reconciled against that source's persistent native-ID registry before Workflow 01. This is an exact source-level delta filter, not bibliographic deduplication. Lens uses Lens ID; Scopus uses EID; OpenAlex uses Work ID; AGRICOLA uses the Europe PMC AGR source plus ID; PubMed/MEDLINE uses MED plus ID; EThOS uses ETH plus ID; Chinese Biological Abstracts uses CBA plus ID; Europe PMC preprints use PPR plus ID; and Web of Science uses UID. Already-known native IDs remain preserved in the raw search archive but are not passed downstream. Only previously unseen native IDs are emitted in the filtered source-shaped harvest consumed by Workflow 01. The updated source-native ID registry is committed only after the selected source jobs have completed successfully.

The supported sources do not expose equivalent update-date semantics, so Workflow 00 records the retrieval mechanism explicitly rather than presenting the searches as methodologically identical:

| Source | Fortnightly retrieval mechanism | Search fields | Important constraint |
|---|---|---|---|
| Lens | `created` date, 14-day window | title, abstract, keyword | Uses Lens creation/indexing metadata. |
| Scopus | `ORIG-LOAD-DATE` after the 14-day boundary | title, abstract, keywords | Uses Scopus load-date metadata. |
| OpenAlex | current publication year plus following publication year | title and abstract only | Deliberate workaround: the workflow does not use the relevant paid date filtering, and title/abstract-only search prevents full-text searching. Previously harvested Work IDs are removed after retrieval. |
| AGRICOLA | `FIRST_PDATE` 14-day window via Europe PMC, restricted to `SRC:AGR` | title and abstract | Provider/API constraint: this is a first-publication-date filter rather than a true indexing-date filter. Previously harvested AGR IDs are removed after retrieval. |
| PubMed/MEDLINE | Europe PMC `CREATION_DATE` 14-day window, restricted to `SRC:MED` | title and abstract | `CREATION_DATE` is the date the record entered Europe PMC. Previously harvested MED IDs are removed after retrieval. |
| EThOS | Europe PMC `CREATION_DATE` 14-day window, restricted to `SRC:ETH` | title and abstract | PhD thesis records only. Previously harvested ETH IDs are removed after retrieval. |
| Chinese Biological Abstracts | Europe PMC `CREATION_DATE` 14-day window, restricted to `SRC:CBA` | title and abstract | CBA records only. Previously harvested CBA IDs are removed after retrieval. |
| Europe PMC preprints | Europe PMC `CREATION_DATE` 14-day window, restricted to `SRC:PPR` | title and abstract | Preprint records only. Published versions remain independent manifestations for Workflow 01 deduplication. |
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

### Search-scoping methods text

> **Search scoping.** Before production retrieval, candidate Boolean search strings could be evaluated using an independent count-only Workflow 00 scoping stage. A manually editable database-neutral Boolean expression was validated for balanced parentheses and quotation marks, Boolean grammar and absence of database-specific field codes before any API request was made. The validated expression was translated programmatically into source-specific title, abstract and keyword syntax for Lens, Scopus, OpenAlex, AGRICOLA and Web of Science Core Collection. Only provider-reported hit counts were retained; bibliographic records and raw API responses were not stored. The workflow produced a dated R Markdown/HTML report containing the exact search string and per-source hit counts and did not alter production Workflow 00 state or trigger downstream processing.

## Reporting status

Workflow 00 state integrity is validated by `scripts/updater/workflow_00_validate_state.R`, which requires exactly the five expected sources, valid archive references and harvest checksums, and non-empty duplicate-free source-native ID registries. Source-native ID reconciliation is now consistently enforced for fortnightly updates across all five sources. Automatic replacement of a complete source entry in `current.json` by a fortnightly archive nevertheless remains disabled because a fortnightly archive is a delta, not a complete source snapshot. The logical state model must therefore preserve the baseline plus accepted source-level deltas rather than treating the newest delta archive as the whole source.

Workflow 00 is considered complete when:

- the search strategy is version-controlled;
- selected source searches complete successfully;
- per-source search documentation is generated;
- the complete parent search run is deposited on Zenodo;
- the Zenodo DOI, record identifier and manifest checksum are registered in the repository; and
- downstream restoration of the archived source inputs has been validated.

## Scoping-stage isolation and outputs

The independent search-scoping pathway is intentionally non-destructive and non-promotional. It does **not**:

- harvest or retain bibliographic result records;
- retain raw API responses;
- create RIS files;
- update source-native ID registries;
- alter `current.json` or any other accepted W00 production state;
- create or update a Zenodo deposit;
- trigger Workflow 01; or
- modify the production search strategy in `user_input/workflow00_search_strategy.json`.

For the five API-backed sources, the scoping run writes only the reported count and associated provenance. CAB Abstracts and ProQuest Dissertations & Theses Global are retained in the report as current manual-ingest W00 sources and are marked as not automatically counted because no W00 API implementation exists for them.

The scoping artefact contains:

- `plan/search_plan.json`, recording the exact input string, validation result and generated source queries;
- `search_scope_counts.csv`;
- `search_scope_counts.json`;
- `search_scoping_report.Rmd`; and
- `search_scoping_report.html`.

The exact manually supplied Boolean string, run date, validation status, source, hit count and source status are therefore preserved without creating a bibliographic harvest.


## Europe PMC API source expansion

Four additional API-backed Workflow 00 sources are implemented but intentionally disabled by default pending completion of the current CAB Abstracts and ProQuest Dissertations & Theses end-to-end pipeline update:

- PubMed/MEDLINE: Europe PMC `SRC:MED`;
- EThOS theses: Europe PMC `SRC:ETH`;
- Chinese Biological Abstracts: Europe PMC `SRC:CBA`;
- Europe PMC preprints: Europe PMC `SRC:PPR`.

All four use the same Europe PMC REST transport and pagination implementation but remain separate W00 database sources with separate source selection, search strings, manifests, raw archives, native-ID registries and Zenodo harvest files. Cross-database duplication is intentionally retained until Workflow 01.
