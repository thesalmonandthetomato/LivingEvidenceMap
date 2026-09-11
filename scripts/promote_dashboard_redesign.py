#!/usr/bin/env python3
"""Promote the approved dashboard redesign preview to production presentation.

Default is --check (non-destructive). Use --apply only after visual approval and
after updater workflows promote the intended canonical master.
"""
from pathlib import Path
import argparse
import json
import re
import sys

ROOT = Path(".")
MANIFEST = ROOT / "config/dashboard_redesign_manifest.json"
m = json.loads(MANIFEST.read_text(encoding="utf-8"))
preview_path = ROOT / m["paths"]["preview_html"]
prod_path = ROOT / m["paths"]["production_html"]

parser = argparse.ArgumentParser()
mode = parser.add_mutually_exclusive_group()
mode.add_argument("--check", action="store_true", help="Validate promotion without writing docs/index.html.")
mode.add_argument("--apply", action="store_true", help="Write promoted presentation to docs/index.html.")
args = parser.parse_args()
if not args.apply:
    args.check = True

html = preview_path.read_text(encoding="utf-8")

# Remove preview-only notice.
html, banner_n = re.subn(
    r'<div class="temp-banner"><b>Temporary redesign preview\.</b>.*?</div>',
    "",
    html,
    count=1,
    flags=re.DOTALL,
)

# Production consumes the generated production dashboard JSON.
html, fetch_n = re.subn(
    r"fetch\('dashboard-redesign-temp\.json\?'\+Date\.now\(\)\)",
    "fetch('dashboard.json?'+Date.now())",
    html,
    count=1,
)

checks = {
    "preview banner removed": "Temporary redesign preview." not in html,
    "production data source": "dashboard-redesign-temp.json" not in html and "dashboard.json?'+Date.now()" in html,
    "publication year filter present": 'id="tableYear"' in html,
    "publication year chart present": 'id="yearChart"' in html,
    "topic-species chart present": 'id="topicSpeciesChart"' in html,
    "heatmap reset present": 'id="heatReset"' in html,
    "radial chart present": 'id="topicRadial"' in html,
    "replacement filter semantics present": "window.figureFilter=function" in html,
    "old radial override absent": "./topic-radial.js" not in html,
}
failed = [name for name, ok in checks.items() if not ok]
if banner_n != 1:
    failed.append(f"preview banner replacement count was {banner_n}, expected 1")
if fetch_n != 1:
    failed.append(f"preview data-source replacement count was {fetch_n}, expected 1")

if failed:
    print("DASHBOARD PROMOTION CHECK: FAIL")
    for item in failed:
        print(f"- {item}")
    sys.exit(1)

print("DASHBOARD PROMOTION CHECK: PASS")
print(f"Source: {preview_path}")
print(f"Target: {prod_path}")
print("Production data source: docs/dashboard.json")
print("Routine updater presentation changes required: none")

if args.apply:
    prod_path.write_text(html, encoding="utf-8")
    print(f"APPLIED: wrote {prod_path}")
else:
    print("NO FILES CHANGED. Re-run with --apply to promote the approved preview.")
