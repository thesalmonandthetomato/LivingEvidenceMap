#!/usr/bin/env python3
import json
D=json.load(open('docs/dashboard.json',encoding='utf-8'))
assert D['metrics']['total_records']==13426, D['metrics']['total_records']
R={r['record_id']:r for r in D['records']}
for rid in ('007-888-105-974-856','126-877-219-150-602','178-173-638-093-623'):
    assert 'Rainbow trout' in R[rid]['species'], (rid,R[rid]['species'])
    assert R[rid]['topics'], rid
r=R['112-732-189-061-768']
assert {'CAN','CHL','USA'}.issubset(set(r['iso3'])), r['iso3']
assert r['topics'], r
print('Verified four human-reviewed records in dashboard; total_records=13426')
