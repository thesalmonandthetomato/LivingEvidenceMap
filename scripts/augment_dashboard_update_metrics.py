#!/usr/bin/env python3
"""Add operational search metrics to the dashboard data.

The evidence-map dashboard distinguishes:
- last_search: the most recent successful Lens search;
- last_evidence_update: the most recent master-data update; and
- candidate_search_results_screened: the baseline Lens result count plus raw
  records retrieved by subsequent weekly searches.

The baseline is an explicit snapshot of the Lens search corpus supplied by the
project owner. Subsequent weekly increments count raw Lens results, before the
within-update duplicate removal, so the dashboard represents total search
results rather than unique records retained.
"""
import json
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path('.')
DASHBOARD = ROOT / 'docs/dashboard.json'
BASELINE = ROOT / 'state/search_baseline.json'
HISTORY = ROOT / 'state/search_history.json'
SEARCH_STATE = ROOT / 'state/lens_weekly_harvest.json'

BASELINE_RESULTS = 21851
BASELINE_DATE = '2026-08-24T00:00:00+00:00'


def parse_dt(value):
    if not value:
        return None
    try:
        return datetime.fromisoformat(str(value).replace('Z', '+00:00'))
    except ValueError:
        return None


def load_json(path, default):
    if not path.exists():
        return default
    try:
        return json.loads(path.read_text(encoding='utf-8'))
    except Exception:
        return default


data = load_json(DASHBOARD, {})
metrics = data.setdefault('metrics', {})

# The master-derived date remains the evidence update date.
metrics['last_evidence_update'] = metrics.get('last_update')

# The Lens checkpoint is the authoritative successful-search timestamp.
search_state = load_json(SEARCH_STATE, {})
last_search = search_state.get('updated_at') or search_state.get('last_successful_created')
metrics['last_search'] = last_search

# Count the complete current Lens search corpus at the supplied baseline, then
# add raw results retrieved by searches after that baseline. This intentionally
# includes records subsequently removed as within-update duplicates.
history = load_json(HISTORY, [])
if isinstance(history, dict):
    history = history.get('runs', [])
cutoff = parse_dt(BASELINE_DATE)
increment = 0
for run in history:
    retrieved = parse_dt(run.get('retrieved_at'))
    if cutoff is None or (retrieved and retrieved > cutoff):
        try:
            increment += int(run.get('raw_records_retrieved') or 0)
        except (TypeError, ValueError):
            pass
metrics['candidate_search_results_screened'] = BASELINE_RESULTS + increment
metrics['search_results_baseline'] = BASELINE_RESULTS
metrics['search_results_increment_since_baseline'] = increment
metrics['search_results_screened_definition'] = (
    'Baseline Lens search result count plus raw results retrieved by subsequent '
    'weekly searches, before within-update duplicate removal.'
)

# Keep a small audit block so the provenance is visible in dashboard.json.
data['search_metrics'] = {
    'baseline_results': BASELINE_RESULTS,
    'baseline_date': BASELINE_DATE,
    'increment_since_baseline': increment,
    'total_results_screened': BASELINE_RESULTS + increment,
    'last_search': last_search,
    'last_evidence_update': metrics.get('last_evidence_update'),
}

DASHBOARD.write_text(json.dumps(data, ensure_ascii=False, separators=(',', ':')), encoding='utf-8')
print(f"Last successful search: {last_search}")
print(f"Last evidence update: {metrics.get('last_evidence_update')}")
print(f"Search results screened: {BASELINE_RESULTS + increment:,} ({BASELINE_RESULTS:,} baseline + {increment:,} subsequent raw results)")
