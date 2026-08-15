import json,sys
from pathlib import Path
p=Path('docs/dashboard.json'); d=json.loads(p.read_text(encoding='utf-8'))
missing=[r.get('record_id','') for r in d.get('records',[]) if not r.get('topics')]
invalid_species=[(r.get('record_id',''),s) for r in d.get('records',[]) for s in r.get('species',[]) if s=='Rainbow salmon' or s=='RAINBOW_TROUT']
print(f'Records without topics: {len(missing):,}')
print(f'Invalid species labels: {len(invalid_species):,}')
if missing:
    Path('state/dashboard_missing_topics.txt').write_text('\n'.join(missing),encoding='utf-8')
if invalid_species or missing:
    print('Dashboard validation found unresolved data-quality issues.')
    # Do not block publication of the dashboard while historical records are being repaired.
