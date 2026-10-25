# W08b corrected citation-candidate workflow (25 October 2026)

## Authoritative methodological requirement

This supersedes unfiltered Lens candidate bibliography harvesting and local-only original-strategy filtering as the primary method. Do not trigger existing candidate-harvest or strategy-audit workflows for this path. Preserve their restricted Zenodo outputs as provenance and possible QA evidence, not as the primary candidate selection.

1. From canonical W01/W08 JSONL and source manifestations, create the included-seed crosswalk of canonical record_id, Lens IDs, DOIs and OpenAlex work IDs. Preserve missing values, collisions and ambiguous identities without arbitrary resolution.
2. Deduplicate backward and forward citation IDs within each provider. Persist an immutable edge register: canonical seed record_id, provider, related provider identifier, direction (reference/cited-by/both), and source/checkpoint. Never collapse different providers merely because IDs look similar. Aggregate direction per seed/candidate while retaining the raw edge rows.
3. Search Lens by citation Lens IDs and candidate DOIs (including a DOI-resolution branch), using provider-native `bool.must` (ID-list terms) and `bool.must_not` (the original registered v2 strategy from user_input/workflow00_search_strategy.json). Keep approved batches <=500 input identifiers/request; validate returned identity and complete pagination, checkpoint progress and preserve missing results for retry. Lens positive/negative controls in lens_not_controls.R were previously successful, but the combined production ID/DOI predicate requires its own bounded test.
4. Search OpenAlex by citation OpenAlex work IDs and DOIs not resolved by Lens, using exact-ID OR filters and provider-native text NOT. OpenAlex OR filter limit is 100 identifiers/request; the complete URL must remain below 4094 bytes. Its wildcard search must use exact/unstemmed semantics. Validate combined positive and negative controls, unknown/missing abstracts, scope differences, full pagination and exclusion correctness before full execution. Do not pretend the Lens Boolean query can be reused verbatim.
5. Union the results with cross-provider reconciliation (DOI and supported identifiers), retaining all provider-ID provenance and all seed/direction relationships; quarantine collisions. Exclude anything in historical W01 canonical AND all manifestations, INCLUDING previously excluded records. Do not silently discard records with missing identifier/metadata.
6. Prepare a single isolated, nonrecursive supplemental W01-W08 run, with separate archival and validated counts, and only then a controlled supplementary merge and W09/W10 update. Never modify production W01-W10 or main during development.

## Verified reusable state

- 22,923 included W08 canonical seeds have a checked crosswalk derived from W01 manifestations.
- 16,197 Lens seed citation lookups complete; 66 Lens entries incomplete at checkpoint 23626701.
- 1,277 successful OpenAlex fallback seed lookups, with 404 statuses retained; last combined restricted checkpoint 23627320.
- Lens candidate bibliography harvest succeeded: 336,263 records / 673 requests; checkpoint 23628056. This was performed WITHOUT the required provider-side NOT filter. Retain only for independent audit, not primary pathway.
- Candidate ID register had 336,264 provider-specific IDs at harvest time, NOT distinct publications.
- Existing scripts: crosswalk_identifiers.R, merge_edges.R, run_lens_bulk.R, run_openalex_fallback.R, lens_not_controls.R, filter_existing_w01.R, index_w01_dois.R and reconcile_lens_candidates.R. These are components, not proof the complete method runs.
- Registered strategy: user_input/workflow00_search_strategy.json, search_version v2, includes maricultur*.

## Execution gates

Before costly full execution: parse every new R script; run offline identity/provenance tests; run a small *provider-side AND NOT* positive/negative test for Lens Lens-ID and DOI paths and OpenAlex ID and DOI paths; confirm candidate counts against unfiltered controls and ensure original-search matches are excluded but unrelated candidates retained. Archive checkpoint at every durable boundary; automatically continue all remaining records without requiring a user 'pass' per batch. Stop rather than silently accept truncated output or misapply an identifier. Do not trigger a supplemental W01 handoff until cross-provider and historical W01 reconciliation passes.

No code in this document authorises a production mutation.