# VALIDATED PIPELINE RECOVERY POINT

If development moves to a new ChatGPT conversation, start here.

The authoritative record for the validated Workflow 00 search/update layer is:

`docs/validated_pipeline/WORKFLOW00_VALIDATED_2026-09-22.md`

That manifest contains:
- the exact validated commit SHA for every source implementation;
- frozen recovery branch names;
- successful GitHub Actions validation run IDs;
- validated behaviour and known design decisions;
- the safe promotion procedure for eventually moving the completed pipeline to `main`.

Do not reconstruct the validated search layer from memory or from whichever working branch happens to be current.

For recovery in a new chat, tell ChatGPT:

> Read `VALIDATED_PIPELINE.md` and `docs/validated_pipeline/WORKFLOW00_VALIDATED_2026-09-22.md` in the LivingEvidenceMap repository before making pipeline changes.

Current validated scope: Workflow 00 only. Later validated stages should be added to the same `docs/validated_pipeline/` directory and referenced from this file.
