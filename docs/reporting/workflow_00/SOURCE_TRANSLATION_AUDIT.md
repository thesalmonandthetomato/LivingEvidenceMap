# W00 database-specific query translation audit

**Scope:** static source review of `production-minimal`, 9 October 2026. No R scripts, tests or external database queries executed. A working adapter does not by itself establish equivalent retrieval across sources.

| Source | Adapter/API input | Current generic translator | Action before validation |
|---|---|---|---|
| Lens | `workflow_00_lens_orchestrated_search.R`; generated JSON `query_string` | Title, abstract and keyword fields | Compare produced query and grouping with accepted Lens expression; check NOT and wildcard behaviour |
| Scopus | `workflow_00b_scopus_ingestion.R`; `query` | `TITLE-ABS-KEY(...)` for concept blocks | Verify provider precedence, escaping and date-filter semantics |
| OpenAlex | `workflow_00c_openalex_ingestion.R`; OQL sent as `oql` to API root | Explicit `database_overrides.openalex` mandatory | Confirm the override is valid OQL, and archive the provider's normalized representation if available; OpenAlex official docs confirm API-root OQL execution |
| AGRICOLA | `workflow_00d_agricola_ingestion.R`; Europe PMC `query` parameter | `SRC:AGR` with `TITLE_ABS` blocks | Verify actual Europe PMC coverage and source filtering; no invented equivalence with native AGRICOLA searches |
| PubMed, EThOS, CBA, preprints | `workflow_00f_europe_pmc_source_ingestion.R`; Europe PMC `query` | `SRC:MED/ETH/CBA/PPR` with `TITLE_ABS` blocks | Verify source codes and Boolean handling independently |
| Web of Science | `workflow_00e_wos_starter_ingestion.R`; `q` | `TI/AB/AK` field blocks | Verify Starter API syntax, operator nesting and API date window |
| EBSCO databases | `workflow_00g_ebsco_ingestion.R`; EBSCO `query` | Uses individual configured `search_fields` | Verify EBSCO Boolean syntax, per-database field tags, date semantics and NOT behaviour |

## Confirmed cross-source restrictions

1. The new translator receives the selected-source registry. An earlier workflow wiring error omitted this required argument; it has been corrected on the inert branch.
2. OpenAlex OQL is accepted at the API root in the current adapter. Because OQL syntax and textual matching are not simply interchangeable with the other providers, the generic translator currently requires an explicit OpenAlex override.
3. Named concept terms must be simple atoms or quoted phrases. Boolean, proximity and field syntax embedded within a term is rejected, rather than silently interpreted.
4. The archive contains exact translated query strings as handed to the source child and records their checksums. Zenodo archive publication now checks the query archive before deposition.
5. Full, fortnightly and expansion modes need independently justified provider syntax. The current generic fortnightly mode requires explicit complete provider queries instead of assuming equivalent date filtering across services.

## Unresolved critical items

- Comparison against the previously accepted salmon query for every selected source, including field scope and matching semantics.
- Explicit source-specific review of NOT placement, expansion, proximity operators, wildcards and phrase matching. Where semantics cannot be guaranteed, a full provider override must be required.
- Provenance link from every harvest's actual request and retrieval report to the query archive checksum, not merely the W00 plan.
- Complete W00 documentation migration from fixed species/farming language to topic-agnostic inputs.
- Static R syntax checks and executable dry-run unit tests on a safely isolated branch; no production Actions or API queries until authorised.

**Disposition:** Implementation in progress; none of the adapters or translations are certified for production use by this document.


## Source-by-source static verification, 9 October 2026

The categories below distinguish **documented syntax** from **retrieval equivalence**, which cannot be established without controlled provider requests.

| Source | Supported by reviewed provider documentation | Actual implementation and disposition |
|---|---|---|
| Lens | Scholarly API query strings support AND/OR/NOT, fielded title/abstract searches and range queries; the `created` field exists. https://docs.api.lens.org/request-scholar.html | Legacy translator appends `created:[from TO to]` for fortnightly retrieval. **Documented field, syntactic approach plausible; exact date window boundaries and matching behaviour not live-tested.** The generic route requires a separately supplied dated override. |
| Scopus | The Elsevier developer guide documents `orig-load-date aft YYYYMMDD` as date of first indexing in Scopus. https://dev.elsevier.com/tecdoc_ir_cris_vivo.html | Legacy `ORIG-LOAD-DATE AFT` is consistent with documented semantics. The boundary is exclusive; the 14-day overlap plus ID reconciliation is the intended safeguard. **Syntax supported; coverage not live-tested.** |
| OpenAlex | OpenAlex OQL supports nested text conditions and year comparisons, and accepts OQL at the API root. Its `/query` endpoint validates OQL without searching. https://help.openalex.org/api/oql/ | Legacy current-year through next-year restriction is a **publication-year** window. It is **not equivalent** to a newly indexed/modified-record window and may omit old publications recently incorporated. Keep generic queries explicit; select a deliberate update strategy before enabling generic fortnightly automation. |
| Europe PMC (AGR/MED/ETH/CBA/PPR) | The Europe PMC query reference lists `FIRST_PDATE` and `CREATION_DATE`. https://europepmc.org/docs/EBI_Europe_PMC_Web_Service_Reference.pdf | W00 uses `FIRST_PDATE` for AGR and `CREATION_DATE` for other source codes. These **represent distinct events**, so metadata must report the exact date semantics per source. Source collection availability and actual date boundary handling remain live tests. |
| WoS Starter | Clarivate's Starter client documents `modifiedTimeSpan` as an API query parameter, with `YYYY-MM-DD+YYYY-MM-DD` syntax, and disallows it with `db=WOK`. https://github.com/clarivate/wosstarter_python_client | The W00 adapter uses `db=WOS` and passes the date span separately. **Parameter and format supported; freshness means last modification, not necessarily first indexing.** |
| EBSCO | The EBSCOhost Integration Toolkit exposes a search `query` argument; EDS documentation is **not** sufficient to confirm syntax for this distinct EBSCOhost API. https://eit.ebscohost.com/Pages/MethodDescription.aspx?method=Search&service=%2FServices%2FSearchService.asmx | W00 produces fielded queries using source-specific field tags. **Do not certify their full Boolean compatibility based on EDS documentation alone.** W00 reharvests the full EBSCO query during updates, then reconciles IDs, avoiding an assumed indexing-date field. |

### Concrete defects and decisions

- **Corrected:** the generic translator was not receiving the source-selection JSON from the inert orchestrator. The argument is now passed.
- **Corrected:** empty or invalid fortnightly overrides previously could pass the presence check. A selected source now requires a non-empty scalar string.
- **Known limitation, unresolved:** legacy OpenAlex `year` filtering can miss newly added older records. The generic translator remains fail-closed until an explicit update query is given.
- **Provider-specific exception:** EBSCO update retrieval is a complete query reharvest, not a last-14-days filter.
- **Unverified:** actual retrieval equivalence, exact NOT semantics, wildcard/phrase behaviour, source filters and complete response-code contracts. These need controlled nonproduction API requests following static R syntax checks.
