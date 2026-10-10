# MVP debugging and transfer log

Last updated: 10 October 2026

## Purpose and boundaries

Record fixes made while validating the topic-agnostic MVP on `main` that must be reviewed and, where appropriate, transferred to `workflow01-final-architecture` later. **This file is a record only:** it does not merge, cherry-pick, or modify pipeline code on the production branch. Do not assume these changes are already present there.

For every future fix, append: date, source branch, file(s), commit(s), root cause, exact behaviour changed, test/run evidence, whether it is topic-agnostic, and transfer/validation status. Record workarounds and temporary triggers separately from reusable fixes.

## Changes to review for transfer

| ID | Component | Change on `main` | Evidence / commit | Transfer status |
| --- | --- | --- | --- | --- |
| DBG-001 | W00–W01 fresh-run initiation | Introduced and propagated explicit `first_run` handling (default false), validation of an absent authoritative W08 baseline, initial zero-count status, and W01 / downstream first-run handoff handling. **W01's complete first-baseline path was not yet functionally validated** at the time these changes were made. Inspect the scripts/workflows and trace exact commits on `main` before porting; no single complete W01 fix commit is verified here. | Main first-run implementation, 10 October 2026; validator `scripts/updater/workflow_validate_first_run.R`. | Review and test; do not mark complete |
| DBG-002 | W00 CBA (and new Europe PMC sources) | For a full first run returning zero records, allow an *existing empty* `updated_native_ids.txt` by testing `-f` rather than `-s`. Reconciliation manifest must still be non-empty. | `.github/workflows/_workflow_00_orchestrated_source_child.yml`; [e72279e](https://github.com/thesalmonandthetomato/LivingEvidenceMap/commit/e72279e24921a5319dee46a61d24d043663378e2). CBA passed in W00 run [38069152347](https://github.com/thesalmonandthetomato/LivingEvidenceMap/actions/runs/38069152347). | Validated for CBA; review for transfer |
| DBG-003 | W00 OpenAlex validation | Separate raw retrieval validation from internal Work ID deduplication. Preserve every raw API response; generate `unique_works.jsonl` retaining the first occurrence of each Work ID; log reported total, raw occurrences, unique IDs and duplicates. Raw export below the API count fails; excess is logged as a warning. Unique count is **not** required to equal the reported search count. This supersedes the narrower exact-unique-count fix. | `scripts/updater/workflow_00c_openalex_ingestion.R`; original narrow check [f203fa2](https://github.com/thesalmonandthetomato/LivingEvidenceMap/commit/f203fa287461a80489cd2b0a774757183761eb5b), revised implementation [d693744](https://github.com/thesalmonandthetomato/LivingEvidenceMap/commit/d6937444538ea22129db15dc6d7e07f80b82cf74). Test run [38069704382](https://github.com/thesalmonandthetomato/LivingEvidenceMap/actions/runs/38069704382) was launched; outcome not checked in this log. | Needs runtime and downstream-consumer validation |
| DBG-004 | W00 orchestration / matrix | GitHub Actions silently suppressed `source_matrix_json` as potentially secret even after it contained only source IDs. Use already-accepted `selected_sources_json` for the 26-source matrix. Each child fetches its query from the parent plan artifact and verifies file and query-string SHA-256 hashes. | `.github/workflows/workflow_00_search_orchestrator.yml`, `.github/workflows/_workflow_00_orchestrated_source_child.yml`; [5bcbc8a](https://github.com/thesalmonandthetomato/LivingEvidenceMap/commit/5bcbc8a6c83eadc2ca77ec118f22d48a55b01e95), [11ef1ab](https://github.com/thesalmonandthetomato/LivingEvidenceMap/commit/11ef1ab30fd902faecd85880d7b38bbe8a98600b), [aa894ab](https://github.com/thesalmonandthetomato/LivingEvidenceMap/commit/aa894ab8bdb5a5fb200a4e8a0e59d21d15b5174e), [59ffd43](https://github.com/thesalmonandthetomato/LivingEvidenceMap/commit/59ffd43c66583ae941e729ecde569959429a2261). 26 child jobs launched in [38068716365](https://github.com/thesalmonandthetomato/LivingEvidenceMap/actions/runs/38068716365). | Handoff validated; review for transfer |
| DBG-005 | W00 R dependencies | Newly activated orchestrator initially failed because the added Sheets preflight installed R packages from CRAN and the archived-query planner lacked `digest`. Preflight uses configured Posit Package Manager and planning setup installs `digest`/`jsonlite`. Avoid standalone preflight package-install regressions when porting. | `.github/workflows/workflow_00_search_orchestrator.yml`; [fcb3b8a](https://github.com/thesalmonandthetomato/LivingEvidenceMap/commit/fcb3b8a4975fbde8fa16ae651c06230e2849cdb8), [9883f00](https://github.com/thesalmonandthetomato/LivingEvidenceMap/commit/9883f003a0d850e4ac8ed62844cb1aa50f9b35c0). | Review existing dependency management before transfer |

## MVP-only configuration: do not transfer blindly

- **Temporary push launch:** `main` has a narrowly scoped push trigger controlled by `docs/w00_mvp_launch_20261010.txt`, created to launch the 26-database first-run test. Remove after testing; **do not transplant this temporary trigger** to the production workflow.
- **Test isolation:** `main` uses `LEM_TEST_GOOGLE_SHEET_ID` and a dedicated spreadsheet, `first_run=TRUE`, `dispatch_w01=FALSE`, a narrow salmon-feed test search, and newly created restricted Zenodo deposits. Preserve isolation; do not copy test-specific credentials, search input or hard-coded paths to production.
- **New `unique_works.jsonl` consumer check:** the OpenAlex deduplicated export is supplemental to raw API responses. Before adopting it, establish whether archive/adapter/downstream paths use raw or unique records, and ensure no double counting.

## Pending validation and follow-up

1. Verify final outcome and OpenAlex statistics in W00 run 38069704382 and record any new defects.
2. Validate normal W00 archive-to-Zenodo and Google Sheets recording after a complete 26-source pass.
3. Validate the W01 fresh-run path end-to-end from a genuinely empty baseline, without inheriting production pointers or salmon-specific project data.
4. Before transferring individual commits, compare the corresponding files on `main` and `workflow01-final-architecture`; port behaviour rather than overwriting newer production code.
5. Append future debugging fixes here with their exact commit and validation evidence, including failures and superseded fixes.
