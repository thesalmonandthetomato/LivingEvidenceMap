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

## Adding new issues

For every new defect discovered on `main`, add one entry identifying: **problem, required correction, affected file(s), main commit (if fixed there), and whether still outstanding on workflow01**. Do not record ordinary test runs, successful validation, routine commits, or temporary MVP-only launch settings. Do not mark an issue fixed on workflow01 until that branch has actually been changed.
