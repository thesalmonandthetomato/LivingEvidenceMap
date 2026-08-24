#!/usr/bin/env python3
"""Patch the approved dashboard presentation with search/update status."""
import json
from datetime import datetime
from pathlib import Path

HTML = Path('docs/index.html')
DATA = Path('docs/dashboard.json')
MARKER = '<div id="lem-update-status"'
INSERT_AFTER = '<div id="kpis" class="kpis"></div>'


def display_date(value):
    if not value:
        return 'Not available'
    try:
        dt = datetime.fromisoformat(str(value).replace('Z', '+00:00'))
        return dt.strftime('%d/%m/%y')
    except ValueError:
        return str(value)[:10]


data = json.loads(DATA.read_text(encoding='utf-8'))
metrics = data.get('metrics', {})
search_metrics = data.get('search_metrics', {})
last_search = metrics.get('last_search') or search_metrics.get('last_search')
last_evidence = metrics.get('last_evidence_update') or metrics.get('last_update')
total_screened = metrics.get('candidate_search_results_screened')
try:
    screened_text = f"{int(total_screened):,}"
except (TypeError, ValueError):
    screened_text = 'Not available'

status = (
    '<div id="lem-update-status" class="section" style="padding:12px 16px;margin:0 0 18px">'
    '<div style="display:flex;gap:24px;flex-wrap:wrap;align-items:baseline">'
    f'<span><b>Last search</b> {display_date(last_search)}</span>'
    f'<span><b>Last evidence update</b> {display_date(last_evidence)}</span>'
    f'<span><b>Search results screened</b> {screened_text}</span>'
    '</div>'
    '</div>'
)

html = HTML.read_text(encoding='utf-8')
if MARKER in html:
    import re
    html = re.sub(r'<div id="lem-update-status".*?</div>\n?', status, html, count=1, flags=re.DOTALL)
elif INSERT_AFTER in html:
    html = html.replace(INSERT_AFTER, INSERT_AFTER + '\n' + status, 1)
else:
    raise SystemExit('Dashboard KPI anchor not found; presentation was not modified.')
HTML.write_text(html, encoding='utf-8')
print(f"Dashboard status patched: last_search={display_date(last_search)}, last_evidence_update={display_date(last_evidence)}, screened={screened_text}")
