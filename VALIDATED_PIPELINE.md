# VALIDATED PIPELINE RECOVERY POINT

If development moves to a new ChatGPT conversation, start here.

The authoritative record for the validated Workflow 00 search/update layer is:

`docs/validated_pipeline/WORKFLOW00_VALIDATED_2026-09-22.md`

Workflow 00 is validated for:

- full five-source search;
- fortnightly updating;
- ad hoc five-source expansion.

The final all-source expansion integration validation was GitHub Actions run **35774020363**.

Planning documents for the next stages are:

- `docs/pipeline/WORKFLOW01_WORKFLOW02_RENAMING_PLAN.md`
- `docs/pipeline/WORKFLOW02_REPAIR_ENRICHMENT_SPEC.md`
- `docs/pipeline/WORKFLOW00_CONSOLIDATION_INVENTORY.md`

The validated manifest contains the exact source implementation commit SHAs, successful validation runs, validated behaviour and production-promotion constraints.

Do not reconstruct the validated search layer from memory or from whichever working branch happens to be current.

For recovery in a new chat, tell ChatGPT:

> Read `VALIDATED_PIPELINE.md` and `docs/validated_pipeline/WORKFLOW00_VALIDATED_2026-09-22.md` in the LivingEvidenceMap repository before making pipeline changes.

Current validated scope: Workflow 00 only. The deduplication and enrichment stage-renaming documents are plans, not validation certificates. Later validated stages should be added to `docs/validated_pipeline/` and referenced from this file.
