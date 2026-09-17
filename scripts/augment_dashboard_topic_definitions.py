#!/usr/bin/env python3
"""Add dashboard-only parent-topic definitions to generated dashboard JSON.

This script deliberately does not modify the ontology used by screening or LLM
annotation. It only augments docs/dashboard.json after that dashboard has been
built from the canonical ontology.
"""
import json
from pathlib import Path

DASHBOARD = Path("docs/dashboard.json")
DISPLAY_DEFINITIONS = Path("docs/dashboard-topic-definitions.json")

if not DASHBOARD.exists():
    raise SystemExit(f"Dashboard JSON not found: {DASHBOARD}")
if not DISPLAY_DEFINITIONS.exists():
    raise SystemExit(f"Dashboard topic definitions not found: {DISPLAY_DEFINITIONS}")

payload = json.loads(DASHBOARD.read_text(encoding="utf-8"))
display = json.loads(DISPLAY_DEFINITIONS.read_text(encoding="utf-8"))
core = payload.setdefault("topic_definitions", {})

collisions = sorted(set(core).intersection(display))
if collisions:
    raise SystemExit(
        "Dashboard-only definitions overlap canonical ontology definitions: "
        + "; ".join(collisions)
    )

core.update(display)
DASHBOARD.write_text(
    json.dumps(payload, ensure_ascii=False, separators=(",", ":")),
    encoding="utf-8",
)
print(f"Added {len(display)} dashboard-only parent-topic definitions; canonical definitions unchanged.")
