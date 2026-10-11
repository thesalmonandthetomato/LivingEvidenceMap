# Issues to fix on workflow01-final-architecture

This is a **defect and required-fix register**, not a testing or validation log. Record only problems identified while working on the MVP `main` branch that also need assessment and correction on `workflow01-final-architecture`. An issue remains open until the fix has been applied and checked on that branch. Do not merge or alter production pipeline code merely by updating this file.

## Outstanding fixes

### 1. W01 fresh-run handling
- **Problem:** The pipeline needs an explicit, reliable first-ever W01 run path when no prior canonical W08 baseline exists. Do not assume update-mode state, registry entries or a previous run.
- **Required fix:** Review and implement the necessary first-run initialisation/validation and W00-to-W01 handoff on `workflow01-final-architecture`, preserving normal subsequent-update behaviour.
- **Concrete defect confirmed 10 October 2026:** `.github/workflows/workflow_01_production.yml` unconditionally requires a non-empty `previous_workflow01_pointer_path` and restores prior W01 state, then reads previous summaries/maps throughout candidate generation and cluster merging, even for `first_run=true`. The existing `scripts/updater/workflow_01_initial_deduplication.R` supports only initial union/candidate preparation; it does **not** complete classification, adjudication or baseline publication. A proper first-run path must handle those downstream stages and prevent accidental W02 dispatch. The original workflow has been activated on `main` but was deliberately **not run** in this broken mode.
- **Reference:** First-run changes on `main`, including `scripts/updater/workflow_validate_first_run.R`, `scripts/updater/workflow_01_initial_deduplication.R`, and `.github/workflows/workflow_01_production.yml`.
- **Status:** Needs review/fix on workflow01 branch.

### 2. CBA: zero-result harvest rejected
- **Problem:** A valid CBA query returning zero results passes retrieval and native-ID reconciliation, but the W00 child rejects an empty `updated_native_ids.txt` because it requires non-zero file size.
- **Required fix:** In the relevant full-run native-ID reconciliation step, require that the ID file **exists** (`test -f`), not that it contains records (`test -s`). Continue requiring a non-empty reconciliation manifest. Confirm zero-result sources behave correctly.
- **Reference:** `.github/workflows/_workflow_00_orchestrated_source_child.yml` on `main`; fix commit [e72279e](https://github.com/thesalmonandthetomato/LivingEvidenceMap/commit/e72279e24921a5319dee46a61d24d043663378e2).
- **Status:** Needs review/fix on workflow01 branch.

### 3. OpenAlex: incorrectly rejects complete retrieval when pages repeat Work IDs
- **Problem:** Live cursor pagination can return more raw record occurrences than the initial reported search count, with repeated OpenAlex Work IDs. Requiring the raw or deduplicated count to equal the reported count causes false validation failures.
- **Required fix:** Validate completeness and integrity at the **raw retrieval** stage; compare raw records against the initial reported count (report an excess; investigate/fail a shortfall). Deduplicate exact Work IDs internally, preserving untouched raw API responses and reporting the raw, distinct-ID and duplicate counts. **Do not validate the post-deduplication count against the reported search count.** Review downstream handling of the unique export to avoid double counting.
- **Reference:** `scripts/updater/workflow_00c_openalex_ingestion.R` on `main`; revised fix commit [d693744](https://github.com/thesalmonandthetomato/LivingEvidenceMap/commit/d6937444538ea22129db15dc6d7e07f80b82cf74).
- **Status:** Needs review/fix on workflow01 branch.

### 4. W00: search-source dispatch blocked by GitHub output masking
- **Problem:** GitHub suppresses the generated `source_matrix_json` job output as potentially secret, preventing source-search matrix jobs from starting, even when that output includes only source IDs.
- **Required fix:** Build the matrix from `selected_sources_json` rather than `source_matrix_json`. If queries are obtained through archived parent artifacts, verify integrity hashes and retain provenance.
- **Reference:** `.github/workflows/workflow_00_search_orchestrator.yml` and child on `main`; fix commits [59ffd43](https://github.com/thesalmonandthetomato/LivingEvidenceMap/commit/59ffd43c66583ae941e729ecde569959429a2261) and [11ef1ab](https://github.com/thesalmonandthetomato/LivingEvidenceMap/commit/11ef1ab30fd902faecd85880d7b38bbe8a98600b).
- **Status:** Check whether the issue exists on workflow01 branch; fix if applicable.

### 5. W00: missing R dependencies in planning/preflight
- **Problem:** W00 planning failed because `digest` was not installed. An added Google Sheets preflight also failed when attempting to build dependencies directly from CRAN.
- **Required fix:** Ensure required R packages are installed using the workflow's configured package repository **before** first use. Do not add a separate, incompatible package installation mechanism.
- **Reference:** `.github/workflows/workflow_00_search_orchestrator.yml` on `main`; fix commits [9883f00](https://github.com/thesalmonandthetomato/LivingEvidenceMap/commit/9883f003a0d850e4ac8ed62844cb1aa50f9b35c0) and [fcb3b8a](https://github.com/thesalmonandthetomato/LivingEvidenceMap/commit/fcb3b8a4975fbde8fa16ae651c06230e2849cdb8).
- **Status:** Check whether the issue exists on workflow01 branch; fix if applicable.

### 6. W01 first-run incorrectly dispatches W02 automatically
- **Problem:** After a successful W01 run with no pending human review, the existing workflow initiates W02 even during an isolated first-run MVP test.
- **Required fix:** Gate automatic W02 dispatch behind `first_run != true` for the MVP, or add an explicit downstream-dispatch input. Preserve normal production dispatch semantics after integration.
- **Reference:** `.github/workflows/workflow_01_production.yml` on `main`, fix commit [1f03e5f](https://github.com/thesalmonandthetomato/LivingEvidenceMap/commit/1f03e5f6cfce8c38e8fed1f8aebbabaf79d080d2).
- **Status:** Review on workflow01 branch.

### 7. W01 first-run checkpoint does not preserve original rescoring artefacts
- **Problem:** The W01 pending human-adjudication checkpoint retains the final pair decisions but not the complete original rescoring files (`rescored_sample.csv` and `summary.json`). After Shiny review, the original scoring outputs cannot be faithfully included in the full initial W01 baseline. This can compromise reproducibility and baseline compatibility; it does **not** establish that pair decisions themselves are incorrect.
- **Required fix:** Save those two original files, unchanged, in the pending checkpoint and restore them on resumption. Verify the full published baseline contains the original files and that downstream baseline restoration uses them as expected.
- **Affected files:** `scripts/updater/workflow_01_build_pending_checkpoint.R`, W01 production workflow and `workflow_01_resume_after_human_review.yml`.
- **Evidence:** Confirmed `workflow01-final-architecture` lacks `--rescore-dir` and `initial_rescore` snapshot handling on 10 October 2026. `main` fixes [6e17a07](https://github.com/thesalmonandthetomato/LivingEvidenceMap/commit/6e17a075fee1e86e6c05a9bb8bea170ec50a6d17), [e14e738](https://github.com/thesalmonandthetomato/LivingEvidenceMap/commit/e14e7384c0d701773af0a43685ce564d50de9c66) and [3f2ee19](https://github.com/thesalmonandthetomato/LivingEvidenceMap/commit/3f2ee190848cb2fea1b3f59680d6f63d0d131d5e).
- **Status:** Open on workflow01 branch. Inspect original workflow path and only port where applicable.

## Adding new issues

For every new defect discovered on `main`, add one entry identifying: **problem, required correction, affected file(s), main commit (if fixed there), and whether still outstanding on workflow01**. Do not record ordinary test runs, successful validation, routine commits, or temporary MVP-only launch settings. Do not mark an issue fixed on workflow01 until that branch has actually been changed.

### 8. OpenAlex adapter rejects repeated work IDs across W00 raw pages
- **Observed:** W01 initial integration run 38075196803 failed at "Prepare updated and preserved API source inputs" with `Duplicate OpenAlex sidecar_record_id values found`, before LLM calls.
- **Correction on main:** `scripts/updater/workflow_01u_openalex_sidecar_adapter.R` commit cfc1244. It preserves the first occurrence of an OpenAlex work ID, records identical repeats in `duplicate_source_occurrences.jsonl`, and fails closed when mapped bibliographic metadata conflict. Deduplication algorithms and canonical schemas are untouched.
- **Production branch:** Assess whether the same adapter issue applies; port with appropriate validation, not by merging unrelated main work.
- **Status:** Main correction awaiting integration rerun; production branch unresolved.


### 9. Europe PMC-derived W00 sources lack generic normalised JSONL handoffs
- **Observed:** W01 first-run 38075483055 passed OpenAlex (2,426 unique records), AGRICOLA and WoS, then failed at PubMed with `No normalized records.jsonl handoff found for API source pubmed`; no LLM calls.
- **Cause:** W00 retains raw Europe PMC responses for PubMed (MED), EThOS (ETH), CAB Abstracts (CBA), and preprints (PPR). The W01 generic path assumes `records.jsonl` and did not invoke the existing `workflow_01x_europe_pmc_sidecar_adapter.R`.
- **Main correction:** commit 6a2542e: route these four formats through the existing R adapter, retaining input schemas and source identities; fail closed on unsupported source layouts.
- **Status:** Awaiting main integration validation. Assess/port to production branch after verification.

### 10. Multiple prepared inputs for Europe PMC source
- **Observed:** W01 initial run 38075736402 failed in the source catalogue with `Expected one prepared W00 input for pubmed, found 2`.
- **Cause:** The Europe PMC adapter created `pubmed_sidecar_records.jsonl`, then the W01 preparation copied the same records to `records.jsonl` in the same directory. The existing runtime catalogue correctly rejects ambiguous inputs.
- **Main correction:** Commit `f2322da` moves (rather than copies) the adapter output to the sole standard `records.jsonl`, preserving content and avoiding duplicate candidate files.
- **Status:** Main integration retest pending; assess same fix for production branch.

### 11. OpenAlex W00 occurrence counts differ from unique W01 manifestations
- **Observed:** Initial W01 integration run 38076040704 failed count validation: 2,426 OpenAlex W00 occurrences versus 2,422 unique OpenAlex source records after duplicate work IDs were removed.
- **Cause:** Source catalogue required raw W00 download count to equal deduplicated W01 record count, without accounting for the adapter's audited four identical repeated work IDs.
- **Main fix:** `scripts/updater/workflow_01_prepare_source_catalogue.R` commit `83f50a5` validates W00 raw count = unique prepared records + individually logged identical duplicate occurrences. It rejects inconsistent counts, missing audit files and mismatched ledger lengths.
- **Validation:** Synthetic positive and negative reconciliation cases passed in Actions run 38076435811, which also passed all earlier W01 offline tests.
- **Status:** Production branch requires assessment and appropriate porting before deployment. Full W01 live rerun not yet attempted following correction.

### 12. Historical human benchmark labels incorrectly required for W01 first-run classifier
- **Observed:** Run 38077293901 passed source validation and candidate scoring, then failed in `workflow_01_deduplication_identifier_rescore.R` because `data/validation/workflow02_v2_human_labels_2026-09-21.csv` was removed from the cleaned repository.
- **Original file:** archived at `legacy-pre-pipeline-cleanup-20261005`; 205 historical pair labels (166 duplicate, 39 not_duplicate), columns `record_i,record_j,truth,review_group,original_review_rule`. Numeric IDs belong to an older corpus and must not be reused as current W01 IDs.
- **Main correction:** commit `a6de132`. Missing benchmark becomes a zero-row optional evaluation input; deterministic rescore rules and primary `rescored_sample.csv` output are unchanged, and evaluation outputs are retained. Explicit `--benchmark-labels` supports historical benchmarking if appropriate.
- **Production branch:** assess and port only if applicable. Main integration rerun pending.

### 13. Remove historical benchmark evaluation from the W01 classifier
- **Reason:** The numerical-ID historical benchmark is tied to an obsolete dataset and inappropriate for current first-run classification.
- **Main change:** Commit `7c74c89` removes benchmark CSV loading, benchmark-only join/metrics and historical CSV output from `scripts/updater/workflow_01_deduplication_identifier_rescore.R`. The benchmark CSV is already absent on main and remains archived on `legacy-pre-pipeline-cleanup-20261005`. No production decisions, rescored CSV generation, core classifier rule, or primary summary metric was modified.
- **Evidence:** Exact source comparison against commit `a6de132` confirms only benchmark-specific sections were removed; isolated R parse and source equivalence Actions validation is being completed.
- **Production branch:** This note only; do not alter production implementation until the current work is safely reconciled.

### 14. OpenAlex partial matching broke W01 LLM case construction
- **Observed:** W01 run 38078768540 failed during case building (`raw$abstract` on logical value); no OpenAI adjudication calls made.
- **Root cause:** R `$` partial matching on `container$raw_payload` matched OpenAlex metadata flag `raw_payload_duplicated_in_w01=FALSE` because embedded raw payload is intentionally absent. All 25 OpenAlex records in 101-record/104-pair adjudication selection had this structure.
- **Main correction:** commit `1b0296ad` replaces raw lookup with `container[["raw_payload", exact = TRUE]]` while retaining safe object guard from `ed294d3`. Other classification and case fields unchanged.
- **Evidence:** isolated source reconstruction and real 104-pair case build PASSED in Actions run 38081525482 without LLM calls or external publication.
- **Rerun:** controlled W01 launch 38081853866, first_run true; W02 dispatch disabled; max_llm_cases 5000.
- **Production branch:** note only, port fix if implementation affected.

### W01 Shiny Google Sheets intermittent save stalls (10 Oct 2026)
- **Observed:** W01 reviewer reported intermittent Shiny blocking overlay and Google Sheets retry countdown while adjudicating 38 assigned records in batch w01-run-38081853866.
- **Cause investigated:** W01 save path used an active-decision log read followed by append and another full-log read for verification; uncertain HTTP write outcomes could lead to resubmission risks. Google API throttling is plausible, not confirmed from deployment logs.
- **Shiny repo main fix:** LivingEvidenceMapAdjudication commit 6da8ddf removes redundant nested active-log read, preserves pre-write cross-reviewer authority, detects previously written decision IDs, performs only one append attempt, and verifies by ID after append even if the HTTP response fails. It returns a clear, cautious error if verification cannot determine persistence. Reference copy synchronised b0330ac.
- **Safety:** No Google Sheet writes or deletion performed during code change. Existing decision events, assignments, queue hashes, and tab schema unchanged. No W00/W01 rerun and no API LLM calls.
- **Follow-up:** Verify regression CI, deployment environment, and live reviewer save latency; resolve separate hard-coded GitHub dispatch refs before pipeline continuation. Do not republish/reset a queue while reviewing.

### W01 initial-run resume historical split-registry failure (11 Oct 2026)
- Run 38086219307 failed at `Apply final adjudications with stable work IDs`: `Explicit split work-653e23e9f79dc507/horses is missing declared manifestation(s)` for legacy Lens and OpenAlex IDs. These belong to `user_input/workflow01_explicit_cluster_splits.json`, a historic salmon-project correction registry inappropriate for a fresh first run.
- Main fix e5c2fdbb: only supply `--explicit-cluster-splits` to W01 resume for non-first-run updates (`LEM_FIRST_RUN != true`), retain prior historical update logic. No changes to Shiny decisions or checkpoint.
- Reuse original exported 38-case handoff `run-38081853866.json` from successful export 38086090236; retry triggered as run 38113970985. Verify publication and downstream activation after run result.
- Production branch: documentation only; no code changes made here.

### W01 topic-specific data and explicit split-registry excision (11 Oct 2026)
- Reusable W01 on `main`: removed explicit historical split-registry argument and implementation from both W01 production/resume workflows and `workflow_01_apply_adjudications_and_recluster.R`. Generic stable work-ID preservation and fail-closed protections against unapproved splitting of existing work IDs remain.
- Removed inherited project-specific configuration files from `main`: `user_input/workflow01_explicit_cluster_splits.json`, `config/workflow01_explicit_cluster_splits.json`, `user_input/workflow01_identifier_never_auto_resolve.csv`, `config/workflow01_identifier_never_auto_resolve.csv`, `user_input/workflow01_manual_sources.json`, and obsolete `config/workflow01_source_catalogue.json`. New reviews may supply their own optional manual-source configuration.
- W01 checkpoint project-configuration snapshot now supports only manual source configuration; legacy archived entries are integrity-checked but not restored to the live project input directory. Removed hard-coded historical benchmark run ID from identifier-rescoring helper. Topic-neutral synthetic titles replace salmon-specific test fixture titles.
- R parsing/project-input isolation validation passed in GitHub run 38114862540. No-API first-run synthetic functional validation passed in run 38114941384. Later change deleting unused static source catalogue under revalidation run 38115000851.
- Active first-run resumption 38113970985 checked out earlier code and remains a distinct, ongoing run; do not restart/cancel it merely for this cleanup. No human decisions modified and no external API calls initiated by validation.

### W02 human-resume publication contract and automatic W03 handover (11 October 2026)
- **Observed on main:** W02 human-resume run [38137255968](https://github.com/thesalmonandthetomato/LivingEvidenceMap/actions/runs/38137255968) correctly applied Shiny decisions and reconstructed 909 patches for 4,212 records, but failed at Zenodo archival because `outputs/workflow02_state/enrichment_report.json` was missing.
- **Root cause and required correction:** The human-resume path omitted the enrichment report required by `workflow_02_archive_state_to_zenodo.R`, although the uninterrupted W02 path produces it. Reconstruct the report from immutable source-run batch reports and the original plan using `workflow_02_aggregate_batches.R`; include it in the state archive on *every* human-resume run. The correction is on `main` in commit [ea4507d](https://github.com/thesalmonandthetomato/LivingEvidenceMap/commit/ea4507db823b4ca21ba8c059d529b91d9c8dab67). Check applicability before porting to the salmon-farming implementation.
- **Follow-up observed:** Retest [38137694653](https://github.com/thesalmonandthetomato/LivingEvidenceMap/actions/runs/38137694653) successfully published and registered W02, acknowledged the human batch, and published/verified the lean W03 checkpoint (4,212 records), but failed on the final W03 dispatch (HTTP 422: W03 workflow has no active `workflow_dispatch` trigger). W03 is still inactive under `.github/workflows-inert/` on `main`; activation and end-to-end W02→W03 automatic handover must be validated. The failure does *not* imply W02 enrichment state publication failed.
- **Affected files:** `.github/workflows/workflow_02_resume_after_human_review.yml`, `scripts/updater/workflow_02_aggregate_batches.R`, `scripts/updater/workflow_02_archive_state_to_zenodo.R`; downstream `.github/workflows/workflow_03_production.yml` activation and W02→W03 dispatch configuration.
- **Production requirement:** Automatic workflow handover must work for first runs and updates, including after human adjudication. Check both W02 no-human and human-resume paths on the salmon-farming branch. No synthetic launch helper should become part of the production handover.
- **Status on workflow01-final-architecture:** Logged for assessment/correction if applicable. No legacy implementation code changed.
