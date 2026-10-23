#!/usr/bin/env python3
"""Static routing check. Read-only, no Actions expressions in workflow run blocks."""
from pathlib import Path
t=Path(".github/workflows/workflow_01_production.yml").read_text()
for name in ("prepare","fast_shadow","adjudicate","canonicalise","publish"):
    assert f"  {name}:\n" in t, f"Missing {name}"
assert t.count("default: legacy")>=2
assert "if: ${{ inputs.w01_engine == 'fast' }}" in t
assert t.count("if: ${{ inputs.w01_engine != 'fast' }}")==2
assert "if: ${{ inputs.w01_engine != 'fast' && needs.adjudicate.outputs.pending_count == '0' }}" in t
shadow=t.split("  fast_shadow:\n",1)[1].split("  adjudicate:\n",1)[0]
assert "ref: w01-fast-direct-delta" in shadow
assert "--delta-writer direct" in shadow
assert "certify_zero_review_ledger.R" in shadow
assert "assemble_publication_shadow.R" in shadow
assert "AWAITING_HUMAN_REVIEW" in shadow
assert "steps.fast_execution.outputs.review_pending == 'false'" in shadow
assert "human_review_package/" in shadow
assert "publication_shadow/publication_shadow_manifest.json" in shadow
assert shadow.index("certify_zero_review_ledger.R") < shadow.index("assemble_publication_shadow.R")
assert "workflow01-stage-canonicalise-" not in shadow
assert not any(x in shadow for x in ("workflow_01_archive_delta_to_zenodo.R","workflow_02_batched_production.yml","gh workflow run"))
legacy=t.split("  adjudicate:\n",1)[1].split("  canonicalise:\n",1)[0]
assert "ref: workflow01-final-architecture" in legacy
prepare=t.split("  prepare:\n",1)[1].split("  fast_shadow:\n",1)[0]
assert "--validate-index-only true" in prepare
assert "if [ \"$W01_ENGINE\" = fast ]" in prepare
assert "if [ \"${{ inputs.w01_engine || 'legacy' }}\" = legacy ]" in prepare
assert "files+=(outputs/workflow01_candidates/all_candidate_pairs.csv)" in prepare
assert "sha256sum \"${files[@]}\"" in prepare
assert "ref: ${{ inputs.w01_engine == 'fast' && 'w01-fast-direct-delta' || env.WORKFLOW01_BRANCH }}" in prepare
print("PASS: legacy default, isolated Fast routing, no Fast publication or W02 dispatch")
