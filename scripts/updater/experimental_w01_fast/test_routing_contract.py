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
assert not any(x in shadow for x in ("workflow_01_archive_delta_to_zenodo.R","workflow_02_batched_production.yml","gh workflow run"))
legacy=t.split("  adjudicate:\n",1)[1].split("  canonicalise:\n",1)[0]
assert "ref: workflow01-final-architecture" in legacy
print("PASS: legacy default, isolated Fast routing, no Fast publication or W02 dispatch")
