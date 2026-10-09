# Minimal production reconstruction: dependency manifest

Source branch: `workflow01-final-architecture` at `6eca21aea0b90b5c870bc25ff171ed647067de50` (read-only). Adjudication app: `LivingEvidenceMapAdjudication/main` (read-only).

## Current snapshot

- Files in reconstruction: **244**.
- Copied production workflow entry points and direct W00–W10 scripts, shared R modules and coding reference files.
- Copied Shiny publish queue workflows and W04/W08 resume/export helpers.
- Copied W09 manuscript R Markdown, bibliography, figure R source, RIS export and human validation report code.
- Copied stage Zenodo registries W01 and W04–W08; included live-status JSON and W04 kappa registry.
- Excluded historical temporary repair workflows, generated reports, PNG/PDF output, and past run artefacts.

## Structural spot check

- PRESENT: `docs/reporting/workflow_09/manuscript/long_form_methods.Rmd`
- PRESENT: `docs/reporting/workflow_09/manuscript/long_form_results.Rmd`
- PRESENT: `docs/deduplication/zenodo_registry.csv`
- PRESENT: `scripts/updater/workflow_08_export_shiny_decisions.R`
- PRESENT: `scripts/updater/workflow_04_export_shiny_resolution_decisions.R`
- PRESENT: `docs/reporting/workflow_09/figure_code/figure_01_flow_diagram.R`
- PRESENT: `docs/current_run/current_run_status.json`

## Outstanding blockers before executing **any** workflow

1. Complete transitive `source()` / `read*` / dynamic file path audit, including non-R scripts and templates.
2. Audit Shiny's dispatch, queue polling, GitHub writes and Google Sheets requests in both directions. Names of dispatch workflows were checked; runtime integration has **not** been validated.
3. Check W00/W01–W08 Zenodo pointer read/write contracts, including new-run resumption and human review state. GitHub state files copied from production are historical and must not become independent authoritative state.
4. Confirm correct W09 and W10 generation/publication files, output paths and provenance, and isolate live Pages publication.
5. Replace or gate hardcoded `workflow01-final-architecture` branch targets and live organisation GitHub dispatches. **Do not run on this branch before isolation.**
6. Run R parse, YAML syntax, file closure and safe fixtures. No end-to-end test yet.

## Verification status

File presence checked for Shiny dispatch filenames and selected W09/W10 paths. This is **not** full validation; unresolved generated files and runtime-dependent paths remain.
