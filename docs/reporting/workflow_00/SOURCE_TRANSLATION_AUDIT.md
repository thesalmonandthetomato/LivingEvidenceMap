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
