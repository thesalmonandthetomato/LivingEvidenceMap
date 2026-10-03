# Workflow 01 assist transfer manifest

## Purpose

This manifest defines the **selective** transfer from `w01-identifier-assist-test` to the current `workflow01-final-architecture` branch.

The experimental branch must **not** be merged wholesale. At the time of this audit it had diverged substantially from the primary Workflow 01 branch and contained temporary validation workflows, benchmark scripts, test reports, and unrelated EBSCO/OpenAlex work.

Source branch audited: `w01-identifier-assist-test`

Source head at manifest creation: `75405591ac00218d6b4382837757a272093e088e`

Destination branch: `workflow01-final-architecture`

## Files to transfer

Exactly these seven permanent files belong to the Workflow 01 identifier/title-assist change set:

1. `.github/workflows/workflow_01_production.yml`
2. `config/workflow01_identifier_never_auto_resolve.csv`
3. `docs/deduplication/workflow01-identifier-title-assist.md`
4. `scripts/updater/workflow_01_identifier_assist_build.R`
5. `scripts/updater/workflow_01_identifier_prescore_collapse.R`
6. `scripts/updater/workflow_01_identifier_inject_decisions.R`
7. `scripts/updater/workflow_01_title_assist_resolve.R`

The identifier builder in the transfer set is the faster hashed, non-chunked implementation validated in run 37045102681. It is byte-for-byte identical to the implementation at commit `e9367db78ba8bca811f9ab1eae41d40819734199`.

## Files explicitly excluded

Do not transfer temporary `tmp_*` workflows, exploratory identifier benchmark scripts, title-wrapper audit scripts, test-only JSON reports, or unrelated source-adapter work.

In particular, the transfer must exclude:

- all `.github/workflows/tmp_*.yml` files created for identifier/title-assist benchmarking or validation;
- `docs/deduplication/tests/w01_identifier_*.json` benchmark/test reports;
- all `scripts/updater/workflow_01_identifier_*_test.R` and exploratory validation/triage scripts;
- `scripts/updater/workflow_01_title_wrapper_audit.R`;
- `scripts/updater/workflow_00g_ebsco_ingestion.R`;
- `scripts/updater/workflow_01u_openalex_sidecar_adapter.R`.

The latter two contain unrelated database/source-adapter work and must be handled separately in their own validated change set.

## Core scripts that must remain unchanged

After transfer, the following core Workflow 01 scripts must remain identical to the destination branch version that existed immediately before transfer:

- `scripts/updater/workflow_01_deduplication_build_union.R`
- `scripts/updater/workflow_01_deduplication_incremental_candidates.R`
- `scripts/updater/workflow_01_deduplication_incremental_score.R`
- `scripts/updater/workflow_01_deduplication_identifier_rescore.R`
- `scripts/updater/workflow_01_deduplication_merge_clusters.R`

The assist architecture is intentionally additive around these existing components.

## Post-transfer validation required

After the seven files are copied onto the then-current head of `workflow01-final-architecture`, run a branch-local integration check that confirms:

1. the four assist scripts parse successfully;
2. `workflow_01_production.yml` invokes the identifier builder;
3. it applies `config/workflow01_identifier_never_auto_resolve.csv`;
4. it runs candidate collapse before expensive scoring;
5. the scorer reads the collapsed candidate directory;
6. safe identifier edges are injected after deterministic rescore;
7. the title-assist resolver operates on the injected decision table;
8. cluster merging reads `final_incremental_decisions.csv`;
9. the compact human-review checkpoint also stores `final_incremental_decisions.csv`;
10. there is no remaining direct rescore-to-cluster or rescore-to-checkpoint bypass;
11. the five core W01 scripts listed above are unchanged.

A second full 118,527-manifestation benchmark replay is not required solely for transfer because the combined architecture has already passed the full frozen-corpus replay. The destination-branch validation is an integration/wiring check.

## Validated evidence carried by this transfer

The validated frozen-corpus results are documented in `docs/deduplication/workflow01-identifier-title-assist.md`.

Key acceptance results were:

- 503,245 ordinary incremental candidate pairs;
- 272,169 representative pairs requiring expensive scoring;
- 45.9172% reduction in expensive scoring decisions;
- exact classification and rule reproduction for all 272,169 retained scored pairs;
- 26 of 285 remaining manual-review pairs resolved by conservative title assistance;
- 259 remaining manual-review pairs;
- 0 baseline cluster splits;
- 0 unsupported merged clusters;
- 0/364 known unsafe/risky pairs merged after transitive closure in the frozen validation corpus.

## Deferred work

Historical old-old deduplication repair is not part of this transfer.

It is deliberately deferred until the planned addition of further EBSCO databases, when a controlled re-deduplication migration can combine database expansion and historical repair in one provenance-tracked canonical-state transition.
