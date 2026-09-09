#!/usr/bin/env python3
import csv, json
from pathlib import Path

MASTER=Path('data/master/current/living_evidence_map_master.csv')
IDS=set('''007-888-105-974-856
017-694-233-138-585
017-868-173-388-589
020-679-699-324-462
022-354-473-357-939
045-591-539-593-939
051-006-201-009-456
054-410-766-228-166
058-538-757-643-833
077-921-841-436-774
079-027-149-533-689
083-099-236-148-874
087-762-072-593-755
095-351-403-133-82X
097-486-039-982-833
110-865-956-750-596
112-732-189-061-768
113-350-847-393-194
122-006-219-661-577
126-877-219-150-602
130-051-571-555-59X
134-721-759-387-001
137-565-925-689-855
140-104-320-905-275
141-814-290-758-587
153-619-376-496-372
158-869-118-584-197
161-597-734-223-741
162-966-605-124-592
166-777-675-844-66X
171-310-410-629-931
171-455-002-907-143
173-526-465-433-579
178-173-638-093-623
181-282-713-255-882
184-944-661-179-679
188-138-616-151-764'''.splitlines())

def v(r,k): return str(r.get(k,'') or '').strip()
def norm(s):
    out=[]
    for x in [z.strip() for z in s.split(';') if z.strip()]:
        if x=='Rainbow salmon': x='Rainbow trout'
        if x=='Unspecified species': x='Unspecified farmed salmon'
        out.append(x)
    return '; '.join(out)

with MASTER.open(newline='',encoding='utf-8-sig') as f:
    rd=csv.DictReader(f); fields=list(rd.fieldnames or []); rows=list(rd)
hit=0
for r in rows:
    if v(r,'record_id') not in IDS: continue
    hit += 1
    hs,ds=v(r,'human_species_decision'),v(r,'deterministic_species')
    sp=norm(hs or ds)
    if sp:
        r['final_species']=sp
        r['species_source']='human adjudication' if hs else 'deterministic'
    hg,dg=v(r,'human_geography_decision'),v(r,'deterministic_primary_iso3c')
    geo=hg or dg
    if geo:
        r['final_primary_country_iso3c']=geo
        r['geography_source']='human adjudication' if hg else 'deterministic'
    if v(r,'record_id')=='126-877-219-150-602': r['deterministic_species_ids']='ONC_MYKISS'
    if hs: r['species_review_required']='FALSE'
    if hg: r['geography_review_required']='FALSE'
if hit != 37: raise SystemExit(f'Expected 37 records, found {hit}')
byid={v(r,'record_id'):r for r in rows}
for rid in ('007-888-105-974-856','126-877-219-150-602','178-173-638-093-623'):
    assert v(byid[rid],'final_species')=='Rainbow trout', (rid,v(byid[rid],'final_species'))
assert v(byid['112-732-189-061-768'],'final_primary_country_iso3c')=='CAN; CHL; USA'
assert v(byid['126-877-219-150-602'],'deterministic_species_ids')=='ONC_MYKISS'
with MASTER.open('w',newline='',encoding='utf-8') as f:
    wr=csv.DictWriter(f,fieldnames=fields,extrasaction='ignore'); wr.writeheader(); wr.writerows(rows)
print(f'Repaired {hit} weekly records; master rows={len(rows)}')
