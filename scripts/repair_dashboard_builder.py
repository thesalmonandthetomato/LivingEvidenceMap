#!/usr/bin/env python3
from pathlib import Path

p = Path('scripts/build_dashboard_html_v2.py')
s = p.read_text(encoding='utf-8')

# Repair known dashboard-builder syntax issue.
bad = "scrollIntoView({behavior:'smooth',block:'start')}function setFilter"
good = "scrollIntoView({behavior:'smooth',block:'start'});}function setFilter"
if bad in s:
    s = s.replace(bad, good, 1)
    print('Repaired dashboard builder jump() syntax.')

# The world-atlas countries-110m topology uses numeric/M49 IDs, while the
# dashboard metrics are keyed by ISO3.  Join through the explicit map_id_to_iso3
# mapping for both fill/tooltip and click filtering.
bad_map = "attr('fill',d=>color(vals[String(d.id)]||0)).attr('stroke','#fff').attr('stroke-width','.5').on('mousemove',(e,d)=>showTip(e,`<b>${esc(d.properties.name||'Country')}</b><br>${fmt(vals[String(d.id)]||0)} records`)).on('mouseleave',hideTip).on('click',(e,d)=>{const iso=D.map_id_to_iso3?.[String(d.id)];if(iso&&vals[String(d.id)])setFilter({species:state.species,country:iso,topic:null})})"
good_map = "attr('fill',d=>{const iso=D.map_id_to_iso3?.[String(d.id)];return color(vals[iso]||0)}).attr('stroke','#fff').attr('stroke-width','.5').on('mousemove',(e,d)=>{const iso=D.map_id_to_iso3?.[String(d.id)];showTip(e,`<b>${esc(d.properties.name||'Country')}</b><br>${fmt(vals[iso]||0)} records`)}).on('mouseleave',hideTip).on('click',(e,d)=>{const iso=D.map_id_to_iso3?.[String(d.id)];if(iso&&(vals[iso]||0)>0)setFilter({species:state.species,country:iso,topic:null})})"
if bad_map not in s:
    if good_map in s:
        print('Dashboard builder choropleth join already repaired.')
    else:
        raise SystemExit('Expected choropleth join not found; refusing to modify builder')
else:
    s = s.replace(bad_map, good_map, 1)
    print('Repaired dashboard choropleth ISO3/M49 join.')

# This file is also a build trigger: keep the repair step in the dashboard
# build dependency graph so changes to the builder cannot bypass the fix.
p.write_text(s, encoding='utf-8')
