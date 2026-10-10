# MVP cross-repository dependency audit (10 October 2026)

**Status: PARTIAL, NOT a conclusive full dependency or runtime audit.** This document records what was verifiably checked, new corrections, and gaps. Do not treat earlier PASS claims as proof of full closure.

## Scope and exact branch snapshots

- Pipeline: `thesalmonandthetomato/LivingEvidenceMap`, `production-minimal` (changes described below).
- Shiny: `thesalmonandthetomato/LivingEvidenceMapAdjudication`, `main`, tree SHA `d289aa8cc2f023df820ee79fdf26d86bc7cc8d1c`. Read-only, not modified.
- Reference for imported files: pipeline branch `workflow01-final-architecture`. No production branch modifications.
- All pipeline workflow definitions are held in `.github/workflows-inert/`; this is deliberate, and therefore the cross-workflow chain is **not executable as deployed** without coordinated activation.
- No external API or Zenodo requests, Google Sheets mutations, Shiny deployments, or live workflow executions were performed as part of this audit.

## Restored missing dependencies

The following files were fetched verbatim from `workflow01-final-architecture` and committed to `production-minimal`:

| File in MVP | Source blob SHA | Commit |
|---|---|---|
| `.github/workflows-inert/workflow_02_batched_production.yml` | `41ea348bfff92c2c775027a78b68e4ba3c880577` | `13a2676c1bd6acecd4ae4ce70d1d7722157d7197` |
| `.github/workflows-inert/workflow_02_batched.yml` | `e210b8480919cd723662e48b1b2671d13e1f2986` | `91f788fcb2b3856847a6262b10148ae4dff2efd8` |
| `scripts/updater/workflow_02_plan_batches.R` | See source branch | `84feade17755142a7512e67b81e22f1c718ee52f` |
| `scripts/updater/workflow_02_aggregate_batches.R` | See source branch | `1ed4374fb7a3c447d2269749c413061b0da8e610` |
| `scripts/updater/workflow_02_resume_checkpoints.R` | See source branch | `4068bc35bd5bd333a35a4b44385e93fe07cef3e7` |
| `scripts/updater/workflow_02_publish_human_review_queue_to_shiny.R` | See source branch | `765b20e72c3b8f265b632963e63ad005dbfea7ef` |

## Checks completed

1. Parsed the pipeline Git tree and examined the entire set of 28 inactive workflow files for literal `gh workflow run <file>` and local `uses: ./.github/workflows/<file>` references, and referenced script/config filepaths. **No outstanding missing literal workflow target** after the six-file W02 restoration.
2. Confirmed the W01 production and human-resume workflows dispatch `workflow_02_batched_production.yml`, that wrapper invokes `workflow_02_batched.yml`, and the batched workflow has a dispatch to W03.
3. Inspected the four restored W02 R scripts for literal repository script/config references. No additional missing references were found in those four.
4. Inspected Shiny `main` `app.R` and `multiuser_app/app.R` literal R `source()` statements and verified their targets exist relative to each respective app directory.
5. Inspected Shiny `main` GitHub validation workflow's test `source()` references and verified all test files exist.
6. Inspected Shiny `R/github_dispatch.R` references to pipeline workflow names against the MVP's inactive workflow filenames.
7. Confirmed the W08 normal and human-resume pathways retain their required W09 report dispatch.
8. Previously passed local synthetic tests: W00 scoping count parity, W00–W08 static reusable contracts, and selected W06/W07 preparer and W08 partition manifest contracts.

## Findings still requiring action

- **Shiny W02 fallback:** `R/github_dispatch.R` explicitly refers to `workflow_02_resume_request_listener.yml`. That wrapper was deleted from `production-minimal` after an earlier invalid reusable-workflow call was discovered. The direct `workflow_02_resume_after_human_review.yml` exists. Determine whether the fallback needs updating or replacement before Shiny is pointed at the MVP. Do not change the live Shiny code without a coordinated migration.
- **Branch switch:** Shiny's `R/github_dispatch.R` defaults scoping and other workflow dispatches to `workflow01-final-architecture`. Pipeline inactive workflows also contain hard-coded references to that branch. These need coordinated update at deployment; do not change them in isolation.
- **Generated paths:** A naive literal path search reports paths such as `R/input_queue.csv` in embedded command examples; these are not necessarily tracked-file dependencies. Runtime generated paths and external downloads must be validated using actual fixture execution.
- **Not yet covered:** Recursive repository-wide indirect `source()` / dynamic shell invocation checks across all pipeline and Shiny modules; package and secret permissions, all action `uses:` versions, W00–W09 real producer-consumer fixture execution, checksum/pointer restoration, all Shiny queues and resume operations, W09 consumption of W08 canonical outputs.
- **Cannot prove full runtime readiness** without executing a representative synthetic chain and comparing every stage's produced/consumed schemas.

## Evidence and acceptance rule

Evidence is Git history (above), the repo trees and paths, and previous GitHub Actions passing individual tests. **The requirement for a conclusive FULL dependency audit is not satisfied by the checks above.** Completion requires a reproducible, run-linked audit covering every repository script/config reference and Shiny trigger, plus passing end-to-end fixture runs. Any check that only confirms file existence must not be reported as successful functional integration.
