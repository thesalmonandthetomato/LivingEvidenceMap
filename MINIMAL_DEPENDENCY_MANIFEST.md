# Minimal production branch: reconstruction and isolation

Source: `workflow01-final-architecture` at `6eca21aea0b90b5c870bc25ff171ed647067de50`.
Shiny source: `thesalmonandthetomato/LivingEvidenceMapAdjudication/main` (read-only).

## Safety state: INERT

All 27 copied GitHub Actions workflow definitions are held in `.github/workflows-inert/`, **outside** `.github/workflows/`. They retain identical blobs/contents, but are not discoverable as workflow definitions by GitHub Actions on `production-minimal`. Do not move them back until explicit external-write isolation and validation are authorised. The original `workflow01-final-architecture` still has its own workflows and is unchanged.

The stored workflows still contain production targets and credentials, including pushes to `workflow01-final-architecture`, writes to Zenodo, Google Sheets and the public `salmonevidencemap` repository. They are **not safe to run** if reactivated unchanged. The live Shiny app remains connected to production, not this branch.

## Dependencies

Direct scripts from W00–W10 and Shiny workflow dispatches, core R code, W09 RMarkdown/visualisations, ontology/reference files and selected Zenodo registry/state pointers have been copied. Additional direct W00 scoping/manual RIS and W04 kappa scripts were added in this isolation commit. The check is a static inventory, not proof of transitive dependency closure. Generated file paths, `source()` calls inside scripts, runtime-selected paths, templates and Shiny-side reads/writes require further verification.

## Before validation (not yet authorised)

1. Complete static closure review of R imports, dynamic paths and direct entry point dependencies.
2. Define test-only credentials and write-sink guards before restoring Actions workflow definitions.
3. Inspect Shiny callback/state-contract compatibility and isolate dispatch targets.
4. Define which live registry pointers are restored vs generated from Zenodo.
5. Only after approval, perform static parser/structure validation, followed by isolated tests.

**No Actions workflow, OpenAI API, Zenodo publication or Shiny task has been executed from this branch.**
