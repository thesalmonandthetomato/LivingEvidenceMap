# Workflow 00 consolidation inventory

Status: inventory only. Do not delete files until the complete pipeline is validated and promoted.

## Current production candidates

- `.github/workflows/workflow_00_search_orchestrator.yml`
- `.github/workflows/_workflow_00_orchestrated_source_child.yml`

## Temporary validation workflows

These can be removed during final consolidation after the complete pipeline passes:

- `.github/workflows/_temp_five_source_fortnightly_integration.yml`
- `.github/workflows/_temp_wos_fortnightly_validation.yml`

The second file was repurposed several times during validation and most recently launched the all-source expansion integration test.

## Legacy or source-specific workflows to review before removal

Do not delete automatically. Confirm that no downstream workflow or recovery procedure depends on them.

- `.github/workflows/fresh_rebuild_full_lens_search.yml`
- `.github/workflows/test_lens_api_query.yml`
- `.github/workflows/test_lens_full_json.yml`
- `.github/workflows/test_lens_ingestion_v2.yml`
- `.github/workflows/test_lens_url_abstract_scraping_12.yml`
- `.github/workflows/openalex_fulltext_download.yml`
- `.github/workflows/recover_openalex_batch_to_zenodo.yml`

## Not Workflow 00 cleanup targets

The following matched the filename search but belong to downstream or unrelated work and should not be removed as part of Workflow 00 consolidation:

- `.github/workflows/fresh_rebuild_01b_scopus_abstract_enrichment.yml`
- `.github/workflows/test_workflow_01b_scopus_enrichment.yml`
- `.github/workflows/lens-input-validation.yml`
- `.github/workflows/lens-pre-llm.yml`
- `.github/workflows/test_lens_deduplication_v2.yml`
- unrelated temporary dashboard/historical-screening workflows

## Cleanup rule

Only remove obsolete Workflow 00 launchers after:

1. the whole pipeline passes end-to-end on the candidate production branch;
2. Workflow 00 has been consolidated from its validated recovery points;
3. no downstream YAML references the file being removed;
4. a subsequent scheduled production run also passes.
