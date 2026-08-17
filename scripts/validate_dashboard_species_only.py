#!/usr/bin/env python3
"""Validate that adding dashboard species changes only the new species field."""
from __future__ import annotations

import json
from pathlib import Path

CURRENT = Path('docs/dashboard.json')
BASE = Path('/tmp/dashboard-before-species.json')


def main():
    before = json.loads(BASE.read_text(encoding='utf-8'))
    after = json.loads(CURRENT.read_text(encoding='utf-8'))
    assert before.keys() == after.keys(), 'Top-level keys changed'
    assert before['records'].__len__() == after['records'].__len__(), 'Record count changed'
    for i, (b, a) in enumerate(zip(before['records'], after['records'])):
        assert set(a.keys()) == set(b.keys()) | {'species'}, f'Record {i}: keys changed beyond species'
        for k in b:
            assert a[k] == b[k], f'Record {i} field changed: {k}'
        assert isinstance(a['species'], list), f'Record {i}: species is not a list'
    for k in before:
        if k != 'records':
            assert before[k] == after[k], f'Top-level field changed: {k}'
    print(f'Validated {len(after["records"]):,} records: only species was added.')


if __name__ == '__main__':
    main()
