#!/usr/bin/env python3
"""Apply the authoritative dashboard presentation data rules after topic augmentation."""
import csv
import json
import re
from collections import OrderedDict
from pathlib import Path

DASH = Path('docs/dashboard.json')
GAZ = Path('config/global_country_gazetteer_v3.csv')

if not DASH.exists():
    raise SystemExit('docs/dashboard.json not found')

def clean(s):
    return ' '.join(str(s or '').strip().split())

def norm_unspecified(s):
    key = clean(s).lower()
    if key in {'unspecified species', 'unspecified salmon', 'unspecified salmon species', 'salmon unspecified', 'unspecified salmonid', 'unspecified salmonid species'}:
        return 'Unspecified species'
    return clean(s)

def pick(fields, names):
    low = {f.lower(): f for f in fields}
    for name in names:
        if name.lower() in low:
            return low[name.lower()]
    return None

with DASH.open(encoding='utf-8') as f:
    d = json.load(f)

# The authoritative topic field is topic_hierarchy_paths. The database must never
# display the legacy four topic columns or the flattened legacy topic labels.
def path_text(path):
    parts = [clean(x) for x in (path or []) if clean(x)]
    return ' > '.join(parts)

def clean_paths(paths):
    out = []
    seen = set()
    for path in paths or []:
        text = path_text(path)
        if not text or text in seen:
            continue
        seen.add(text)
        out.append([clean(x) for x in path if clean(x)])
    return out

for r in d.get('records', []):
    paths = clean_paths(r.get('topic_paths', []))
    r['topic_paths'] = paths
    # Database presentation: complete hierarchy paths, using the literal separator.
    r['topics'] = [path_text(p) for p in paths]
    r['topic_path_descriptions'] = [
        d.get('topic_definitions', {}).get(path_text(p), '') for p in paths
    ]
    r['species'] = [norm_unspecified(x) for x in r.get('species', []) if clean(x)] or ['Unspecified species']

# Country-name lookup for database tooltips. Keep ISO3 as the filter value.
country_names = {}
if GAZ.exists():
    try:
        with GAZ.open(newline='', encoding='utf-8-sig') as f:
            reader = csv.DictReader(f)
            fields = reader.fieldnames or []
            iso_col = pick(fields, ['iso3','iso_3','alpha3','iso_alpha3','iso3c','iso_a3','iso_a3c','alpha_3'])
            name_col = pick(fields, ['name','country','country_name','name_en','short_name','official_name','country_name_en'])
            if iso_col and name_col:
                for row in reader:
                    iso = clean(row.get(iso_col, '')).upper()
                    name = clean(row.get(name_col, ''))
                    if iso and name:
                        country_names[iso] = name
    except Exception:
        pass

d['country_name_by_iso3'] = country_names

# Eight named farmed salmon/trout species; unspecified is a separate final dashboard
# category rather than being counted as a named species.
preferred_order = [
    'Atlantic salmon', 'Rainbow trout', 'Chinook salmon', 'Coho salmon',
    'Sockeye salmon', 'Chum salmon', 'Pink salmon', 'Masu salmon',
    'Unspecified species'
]
sc = d.get('species_counts', {})
ordered = OrderedDict()
for name in preferred_order:
    if name in sc:
        ordered[name] = sc[name]
for name, count in sc.items():
    if name not in ordered:
        ordered[name] = count
d['species_counts'] = dict(ordered)
d['species_display_order'] = preferred_order
d['species_display_labels'] = {'Unspecified species': 'Unspecified salmon'}
d['metrics']['total_species'] = sum(1 for name in d['species_counts'] if name != 'Unspecified species')

# Keep the finest-topic metric, but make sure the database-facing topic count is
# based on authoritative hierarchy assignments rather than legacy topic columns.
d['metrics']['records_without_topics'] = sum(1 for r in d.get('records', []) if not r.get('topic_paths'))

DASH.write_text(json.dumps(d, ensure_ascii=False, separators=(',', ':')), encoding='utf-8')
print(f"Dashboard presentation data fixed: records={len(d.get('records', [])):,}; named species={d['metrics']['total_species']}; database topics now use ' > ' hierarchy paths; country names={len(country_names):,}")
