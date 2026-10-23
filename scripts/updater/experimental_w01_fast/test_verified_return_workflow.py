#!/usr/bin/env python3
from pathlib import Path
w = Path(".github/workflows/w01_fast_verified_return_resume.yml").read_text()
assert "workflow_dispatch:" in w
assert "checkpoint_run_id:" in w and "export_run_id:" in w
assert "w01-fast-review-checkpoint-$CHECKPOINT_RUN" in w
assert "workflow01-human-decisions-$CHECKPOINT_RUN-$EXPORT_RUN" in w
assert "ingest_shiny_return.R" in w
assert "test -s restored/verified_resume/COMPLETE.json" in w
assert "w01-fast-verified-return-" in w
assert "--phase canonical --reviewed-root restored/verified_resume/reviewed" in w
assert "--delta-writer direct" in w
assert "CANONICAL_REPLAY_PASS.json" in w
assert "w01-fast-reviewed-delta-" in w
assert "previous_pointer_path:" in w
assert "sha256sum -c outputs/workflow01_stage_prepare_checksums.txt" in w
assert r"run-[0-9]+\.json$" in w
assert "contents: read" in w and "actions: read" in w
for forbidden in ("gh workflow run", "ZENODO_ACCESS_TOKEN", "workflow_01_archive_delta_to_zenodo.R",
                  "workflow_02_batched_production.yml", "git push", "sheet_write(", "gh release"):
    assert forbidden not in w, forbidden
print("PASS: manual Fast return consumer is non-publishing, read-only, and artifact scoped")
