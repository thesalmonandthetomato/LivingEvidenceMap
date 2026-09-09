#!/usr/bin/env python3
import argparse, json
from pathlib import Path

p=argparse.ArgumentParser()
p.add_argument('--file', required=True)
p.add_argument('--update-date', required=True)
p.add_argument('--issue-number', required=True)
a=p.parse_args()
path=Path(a.file)
if not path.exists(): raise SystemExit(f'Adjudication file not found: {path}')
data=json.loads(path.read_text())
if str(data.get('update_date','')) != a.update_date:
    raise SystemExit('adjudication update_date does not match workflow input')
if str(data.get('issue_number','')) != str(a.issue_number):
    raise SystemExit('adjudication issue_number does not match workflow input')
print('Adjudication metadata validated')
