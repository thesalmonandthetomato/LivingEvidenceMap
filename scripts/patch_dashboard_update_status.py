#!/usr/bin/env python3
"""Patch the approved dashboard presentation with current update status and model."""
import json
import re
from datetime import datetime
from pathlib import Path

HTML = Path('docs/index.html')
DATA = Path('docs/dashboard.json')
LLM_SCREENING = Path('R/llm_screening.R')
MARKER = '<div id="lem-update-status"'
INSERT_AFTER = '<div id="kpis" class="kpis"></div>'
HIDE_DUPLICATE_KPI = '<style id="lem-hide-duplicate-update-kpi">#kpis .kpi:first-child{display:none}.kpis{grid-template-columns:repeat(5,1fr)}@media(max-width:1000px){.kpis{grid-template-columns:repeat(3,1fr)}}@media(max-width:600px){.kpis{grid-template-columns:1fr 1fr}}</style>'


def display_date(value):
    if not value:
        return 'Not available'
    try:
        dt = datetime.fromisoformat(str(value).replace('Z', '+00:00'))
        return dt.strftime('%d/%m/%y')
    except ValueError:
        return str(value)[:10]


def primary_pipeline_model():
    text = LLM_SCREENING.read_text(encoding='utf-8')
    match = re.search(
        r'screen_salmon_batch\s*<-\s*function\(.*?\bmodel\s*=\s*"([^"]+)"',
        text,
        flags=re.DOTALL,
    )
    if not match:
        raise SystemExit('Could not determine the primary LLM model from R/llm_screening.R.')
    return match.group(1)


def model_display_name(model):
    if model.startswith('gpt-'):
        parts = model[4:].split('-')
        label = f'GPT-{parts[0]}'
        if len(parts) > 1:
            label += ' ' + ' '.join(p.capitalize() for p in parts[1:])
        return label
    return model


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

pipeline_model = primary_pipeline_model()
pipeline_model_label = model_display_name(pipeline_model)

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
if 'lem-hide-duplicate-update-kpi' not in html:
    html = html.replace('</head>', HIDE_DUPLICATE_KPI + '</head>', 1)

html, model_subs = re.subn(
    r'supported by LLMs \(OpenAI [^)]+\)',
    f'supported by LLMs (OpenAI {pipeline_model_label})',
    html,
    count=1,
)
if model_subs != 1:
    raise SystemExit('Could not update the dashboard model label in the project description.')

if MARKER in html:
    html = re.sub(r'<div id="lem-update-status".*?</div>\s*</div>', status, html, count=1, flags=re.DOTALL)
elif INSERT_AFTER in html:
    html = html.replace(INSERT_AFTER, INSERT_AFTER + '\n' + status, 1)
else:
    raise SystemExit('Dashboard KPI anchor not found; presentation was not modified.')
HTML.write_text(html, encoding='utf-8')
print(
    f"Dashboard status patched: duplicate Last update KPI hidden; "
    f"model={pipeline_model_label}; last_search={display_date(last_search)}, "
    f"last_evidence_update={display_date(last_evidence)}, screened={screened_text}"
)
