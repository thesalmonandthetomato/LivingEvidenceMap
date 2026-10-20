# W01-Fast isolated development state

## Protected reference
- Repository: thesalmonandthetomato/LivingEvidenceMap
- Protected reference branch: workflow01-final-architecture
- Frozen starting commit: `8febc7b99ce1f7752c7553ed6023976a643f8621`
- Development branch: `w01-fast-development`
- October W00 archive pointer: `docs/search_record/zenodo/run-39298022062.json`
- Previous W01 authoritative baseline pointer: `docs/deduplication/zenodo/run-39140209398.json`
- Completed October canonicalisation (not published): GitHub Actions run `39400566861`, stage artifact `workflow01-stage-canonicalise-39400566861`
- Established candidate-generator real-data parity: run `39381288665` (1719 pairs; missing 0; extra 0; block differences 0)
- Experimental synthetic cluster updater parity: run `39384971910`
- Cluster-map comparator synthetic test: run `39385516338`

## Guardrails
- All subsequent W01-Fast development commits target ONLY `w01-fast-development`.
- Existing `scripts/updater/workflow_01_*.R` and `.github/workflows/workflow_01_production.yml` are immutable reference code for this project.
- No Zenodo writes, Shiny calls, human-decision edits, production W01 execution or W02 dispatch from W01-Fast.
- Experimental workflows default to `contents: read`; no production secrets.
- No production migration without explicit authorisation.
- Validations should use cheap synthetic fixtures before any frozen-data benchmarks.
- If a test fails, revert to the last passing development commit; never repair production to make a test pass.

## Development milestones
1. Isolate branch and preserve input references: branch created.
2. Audit read/write interfaces: underway.
3. Automated regression and failure-detection tests: underway.
4. Persistent matching index: pending.
5. Append-only decisions and classification parity: pending.
6. Incremental cluster parity on real corpus: pending.
7. Affected-only canonicalisation: pending.
8. Versioned state formats: pending.
9. Compact delta and replay: pending.
10. Resume/rollback checkpoints: pending.
11. End-to-end performance and scientific parity: pending.
12. Migration proposal only: pending.

## Explicit limitations
The October production W01 has not published; available full canonicalisation results are from a cancelled run. The 8.2x improvement applies to candidate generation only. Full scientific parity is not yet established.

## 20 October 2026 continuation
- Confirmed protected branch still identical to frozen `8febc7b99ce1f7752c7553ed6023976a643f8621` via commit comparison.
- Run `39418612392`: passed. Run `39418703657`: failed because `jsonlite` was not installed. Subsequent development workflow already declared both `yaml` and `jsonlite`; verification pending.
- Added isolated negative-control regression fixture `test_regression_comparators.R` in commit `089d21cce452e56de1bad085201e87239b4755e4`.
- CI dependency declaration extended to `data.table` and `digest`, and regression test step added in commit `0fc342412a664fc50ffae787f505de63a771f221`.
- Latest comparator test result remains unverified; do not mark Task 3 passed until successful CI and negative-control assertions.
- Task 2 interface inventory still needs content audit (including file outputs and dependencies), beyond structural extraction.
- All changes confined to `w01-fast-development`; no external state writes, production triggers or migration.
