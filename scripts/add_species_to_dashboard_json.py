#!/usr/bin/env python3
"""Add species to each dashboard database record without changing other record fields."""
from __future__ import annotations

import json
from pathlib import Path

MASTER = Path('data/master/current/living_evidence_map_master.csv')
DASH = Path('docs/dashboard.json')


def split_species(value):
    if value is None:
        return []
    s = str(value).strip()
    if not s or s.lower() == 'nan':
        return []
    # Master species annotations are semicolon-separated when multiple farmed species apply.
    return [x.strip() for x in s.split(';') if x.strip()]


def main():
    import csv

    species_by_id = {}
    with MASTER.open('r', encoding='utf-8-sig', newline='') as fh:
        for row in csv.DictReader(fh):
            rid = str(row.get('record_id', '')).strip()
            if rid:
                species_by_id[rid] = split_species(row.get('species'))

    text = DASH.read_text(encoding='utf-8')
    data = json.loads(text)
    records = data.get('records')
    if not isinstance(records, list):
        raise SystemExit('dashboard.json does not contain a records list')

    for r in records:
        if not isinstance(r, dict):
            raise SystemExit('Non-object record encountered')
        if 'species' in r:
            raise SystemExit('species field already exists in dashboard record')
        rid = str(r.get('record_id', '')).strip()
        if rid not in species_by_id:
            raise SystemExit(f'No master species annotation for record_id={rid}')

        # Append exactly one new field; preserve all existing keys/values.
        r['species'] = species_by_id[rid]

    # Compact JSON output is used for deterministic downstream deployment.
    DASH.write_text(json.dumps(data, ensure_ascii=False, separators=(',', ':')) + '\n', encoding='utf-8')


if __name__ == '__main__':
    main()
