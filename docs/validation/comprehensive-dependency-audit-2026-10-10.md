# Comprehensive dependency audit: evidence and boundaries

Date: 2026-10-10. The audit is **static verification**, NOT a completed end-to-end runtime certification.

## Exact examined trees

- `LivingEvidenceMap`, `production-minimal`, before audit tooling commit: `c5d251a55235cf00a50dc30f7edcc14b63ce1c96`.
- `LivingEvidenceMap`, working reference `workflow01-final-architecture`, tree `6eca21aea0b90b5c870bc25ff171ed647067de50`.
- `LivingEvidenceMapAdjudication`, `main`, tree `ff7baa829c9f00292d0993e73e7c510028836ca9`.

## What was checked directly

| Audit | Scope | Result |
|---|---|---|
| Active workflow inventory | All 28 W00–W10, Shiny-related and reporting workflow YAMLs in `.github/workflows-inert` | All literal `gh workflow run <name>` and `uses: ./.github/workflows/<name>` targets exist within the inert workflow set |
| Script/config references inside workflows | All 28 YAML files | Two classes of apparent missing files are generated R command arguments rather than checked-in code, plus human review package paths generated at runtime. No missing named scripts found |
| Pipeline code reference scan | All 198 R/Python/shell code files | No missing literal executable script path found using the `scripts/`, `R/`, `config/`, `user_input/` path patterns. Two missing historical paths occur only in comments: `R/llm_screening.R` points to `scripts/64_llm_screen_uncertain_records.R`; `R/publication_status.R` points to `scripts/65_remove_retractions_and_notices.R` |
| Shiny code source references | All 63 Shiny R/YAML files | Literal `source("...R")` targets found in source scan exist relative to app roots |
| Shiny obsolete W02 fallback | All 63 Shiny R/YAML files | No reference to `workflow_02_resume_request_listener.yml` or `w02_resume_requests/` found; direct dispatch retained |
| W02 batching dependency chain | W01 normal and resume → W02 wrapper → W02 batch → W03 | Files transferred into `production-minimal`: wrapper and batch YAML plus four referenced W02 R scripts |
| W08 → W09 | Both W08 normal and Shiny-resume workflows | `report_workflow09_figures.yml` dispatch preserved |
| Earlier executable fixture tests | W00 scoping, W00–W08 reusable contracts, W06/W07 preparer and W08 partition | Previously reported as passed by user; not a complete end-to-end chain |

## Restored missing files

- `.github/workflows-inert/workflow_02_batched_production.yml`
- `.github/workflows-inert/workflow_02_batched.yml`
- `scripts/updater/workflow_02_plan_batches.R`
- `scripts/updater/workflow_02_aggregate_batches.R`
- `scripts/updater/workflow_02_resume_checkpoints.R`
- `scripts/updater/workflow_02_publish_human_review_queue_to_shiny.R`

The deprecated W02 fallback listener was removed **only after** removing its caller from both copies of Shiny's `github_dispatch.R`.

## Reproducibility

- Scanner source: `scripts/audit_mvp_dependencies.R`
- Isolated CI definition: `.github/workflows/w00-w09-temporary-full-static-audit.yml`
- Run locally from the pipeline checkout:
  `Rscript scripts/audit_mvp_dependencies.R --shiny-root /path/to/LivingEvidenceMapAdjudication --output /tmp/mvp-audit.json`
- A passing **static** run is not evidence that all networked integrations work. Validate CI run result and its artifact before treating that run as passed.

## Outstanding, **not checked**, and not eligible for a PASS claim

1. Complete synthetic W00→W01→W02→W03→W04→W05→W06→W07→W08→W09 execution using actual producer/consumer outputs, not isolated fixture tests.
2. Paused and resumed human adjudication at W01/W02/W04/W08, including queue format, assignment decisions and GitHub dispatch API responses.
3. Zenodo pointer JSON structures, checksums and reconstruction using fixture data across all consecutive stages.
4. Package resolution, GitHub token permissions, required secrets, conditional workflow expressions and dynamic path expansions in an activated-but-isolated environment.
5. Live Shiny deployment configuration, which still points to `workflow01-final-architecture`. Do not change while `production-minimal` remains inert.
6. W09 report ingestion and W10 public dashboard publishing under new subject-specific inputs.
7. Functional validation of the direct W02 Shiny dispatch against GitHub (currently cannot be assumed from static code inspection).
8. Static scanner does not guarantee detection of dynamic file names, computed source paths, function-level package calls or all embedded shell expressions. Audit findings are not exhaustive proof of runtime correctness.

## Overall judgement

**Static dependency references examined: no unresolved missing named workflow/script found by the enumerated patterns. Runtime end-to-end audit: NOT COMPLETE.** The requirement for conclusive functional evidence cannot be met by static source scans alone. It requires executed, recorded representative fixture runs and validated cross-repository API/queue contracts. Do not merge or activate based solely on this report.
