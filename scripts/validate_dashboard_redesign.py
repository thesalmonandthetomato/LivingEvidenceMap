#!/usr/bin/env python3
"""Validate the dashboard redesign against its machine-readable contract."""
from pathlib import Path
import json
import sys

ROOT = Path(".")
MANIFEST = ROOT / "config/dashboard_redesign_manifest.json"
errors = []

if not MANIFEST.exists():
    raise SystemExit("Missing config/dashboard_redesign_manifest.json")

m = json.loads(MANIFEST.read_text(encoding="utf-8"))
paths = m["paths"]

for key in [
    "production_html","preview_html","canonical_master","preview_master_override",
    "topic_ontology","production_build_workflow","preview_deploy_workflow"
]:
    p = ROOT / paths[key]
    if not p.exists():
        errors.append(f"Missing required path: {key} -> {p}")

preview = (ROOT / paths["preview_html"]).read_text(encoding="utf-8")

required_tokens = {
    "preview data source": "dashboard-redesign-temp.json",
    "publication year filter": 'id="tableYear"',
    "publication year chart": 'id="yearChart"',
    "topic-species chart": 'id="topicSpeciesChart"',
    "hierarchical heatmap reset": 'id="heatReset"',
    "heatmap filter links": "filter database",
    "radial chart": 'id="topicRadial"',
    "replacement figure filter": "window.figureFilter=function",
    "year state": "year:null",
    "top-level topic database option": "(all subtopics)",
    "current-year exclusion": "y<currentYear",
}
for label, token in required_tokens.items():
    if token not in preview:
        errors.append(f"Preview missing {label}: {token}")

order = m["presentation"]["section_order"]
anchors = {
    "geographic_distribution":"Geographic distribution",
    "records_by_publication_year":"Records by publication year",
    "topic_assignment_frequency_by_species":"Topic-assignment frequency by species",
    "species_topic_heatmap":"Evidence by species × topic",
    "topic_hierarchy":"Topic hierarchy",
    "database":'id="database"',
}
positions = []
for item in order:
    token = anchors[item]
    pos = preview.find(token)
    if pos < 0:
        errors.append(f"Missing section anchor: {item}")
    positions.append(pos)
if all(p >= 0 for p in positions) and positions != sorted(positions):
    errors.append("Dashboard sections are not in manifest section_order.")

if "./topic-radial.js" in preview:
    errors.append("Preview loads topic-radial.js, which can overwrite the redesigned coloured radial chart.")

palette = m["presentation"]["palette"]
for colour in palette:
    if colour not in preview:
        errors.append(f"Preview does not contain palette colour {colour}")

if errors:
    print("DASHBOARD REDESIGN VALIDATION: FAIL")
    for e in errors:
        print(f"- {e}")
    sys.exit(1)

print("DASHBOARD REDESIGN VALIDATION: PASS")
print(f"Manifest: {MANIFEST}")
print(f"Preview: {paths['preview_html']}")
print("Routine updater contract: canonical master -> dashboard.json -> Pages deployment")
