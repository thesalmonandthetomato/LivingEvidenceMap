#!/usr/bin/env python3
import csv, json, re
from collections import Counter
from pathlib import Path

MASTER=Path('data/reference/salmon_evidence_map.csv')
DASH=Path('docs/dashboard.json')
HTML=Path('docs/index.html')

with MASTER.open(newline='',encoding='utf-8-sig') as f:
    rows=list(csv.DictReader(f))

# Add country × species counts for the interactive map. Prefer canonical restored fields.
def vals(v):
    s=(v or '').strip()
    if not s or s.lower() in {'na','nan','null','none','[]'}: return []
    if s.startswith('[') and s.endswith(']'):
        try: return [str(x).strip() for x in json.loads(s) if str(x).strip()]
        except Exception: pass
    return [x.strip() for x in re.split(r'\s*;\s*|\s*\|\s*|\s*→\s*',s) if x.strip()]

country_species={}
for r in rows:
    species=vals(r.get('final_species')) or vals(r.get('species')) or ['Unspecified']
    countries=vals(r.get('final_primary_country_iso3c')) or vals(r.get('primary_country_iso3c')) or vals(r.get('country_iso3c'))
    for s in species:
        bucket=country_species.setdefault(s,Counter())
        for c in countries: bucket[c.upper()]+=1

with DASH.open(encoding='utf-8') as f: d=json.load(f)
d['country_iso3_species_counts']={s:dict(c) for s,c in country_species.items()}
DASH.write_text(json.dumps(d,ensure_ascii=False,separators=(',',':')),encoding='utf-8')

html=HTML.read_text(encoding='utf-8')
new_map='''function map(){const el=d3.select('#map');el.selectAll('*').remove();const w=el.node().clientWidth||900,h=500;const svg=el.append('svg').attr('width','100%').attr('viewBox',`0 0 ${w} ${h}`);const projection=d3.geoNaturalEarth1().fitSize([w,h],{type:'Sphere'});const path=d3.geoPath(projection);const species=document.getElementById('mapSpecies').value;const values=species==='__all__'?D.country_iso3_counts:(D.country_iso3_species_counts?.[species]||{});const max=d3.max(Object.values(values))||1;const color=d3.scaleSequential(d3.interpolateRgbBasis([palette[2],palette[1],palette[0],palette[5]])).domain([0,max]);d3.json('https://cdn.jsdelivr.net/npm/world-atlas@2/countries-110m.json').then(world=>{const countries=topojson.feature(world,world.objects.countries).features;svg.append('path').datum({type:'Sphere'}).attr('d',path).attr('fill','#eef3f2');svg.selectAll('path.country').data(countries).join('path').attr('class','country').attr('d',path).attr('fill',d=>color(values[String(d.id)]||0)).attr('stroke','#fff').attr('stroke-width','.5').on('mousemove',(ev,d)=>tip(ev,`<b>${esc(d.properties.name||'Country')}</b><br>${fmt(values[String(d.id)]||0)} records`)).on('mouseleave',hideTip);svg.append('text').attr('x',12).attr('y',h-12).attr('fill',palette[1]).attr('font-size',11).text(species==='__all__'?'Darker = more records':'Darker = more records for '+species)}).catch(()=>el.append('p').attr('class','legend').text('World map geometry could not be loaded.'))}'''
new_heat='''function heatmap(){const el=d3.select('#heatmap');el.selectAll('*').remove();const level=document.getElementById('heatLevel').value,limit=+document.getElementById('heatLimit').value,sf=document.getElementById('heatSpecies').value,counts=D.species_topic_level_counts[level]||{};let topics=Object.entries(D.topic_level_counts[level]||{}).sort((a,b)=>b[1]-a[1]).slice(0,limit).map(x=>x[0]);let species=Object.keys(D.species_counts).sort((a,b)=>D.species_counts[b]-D.species_counts[a]);if(sf!=='__all__')species=[sf];if(!topics.length||!species.length){el.append('p').attr('class','legend').text('No topic-level data available.');return}const w=Math.max(el.node().clientWidth,760),cellW=Math.max(26,Math.min(55,(w-190)/topics.length)),cellH=34,left=175,top=25,bottom=135,height=top+species.length*cellH+bottom,totalW=Math.max(w,left+topics.length*cellW+20),svg=el.append('svg').attr('width','100%').attr('viewBox',`0 0 ${totalW} ${height}`),vals=species.flatMap(s=>topics.map(t=>counts[`${s}|||${t}`]||0)),color=d3.scaleSequential(d3.interpolateRgbBasis([palette[2],palette[1],palette[0],palette[5]])).domain([0,d3.max(vals)||1]);svg.selectAll('g.row').data(species).join('g').attr('transform',(s,i)=>`translate(${left},${top+i*cellH})`).each(function(s){const g=d3.select(this);g.selectAll('rect').data(topics).join('rect').attr('class','heat-cell').attr('x',t=>topics.indexOf(t)*cellW).attr('width',cellW).attr('height',cellH).attr('fill',t=>color(counts[`${s}|||${t}`]||0)).on('mousemove',(ev,t)=>tip(ev,`<b>${esc(s)}</b><br>${esc(t)}<br>${fmt(counts[`${s}|||${t}`]||0)} records`)).on('mouseleave',hideTip)});svg.append('g').selectAll('text').data(species).join('text').attr('x',left-8).attr('y',(s,i)=>top+i*cellH+cellH/2+4).attr('text-anchor','end').attr('class','axis').text(d=>d);svg.append('g').selectAll('text').data(topics).join('text').attr('transform',(t,i)=>`translate(${left+i*cellW+cellW/2},${top+species.length*cellH+18}) rotate(-55)`).attr('text-anchor','end').attr('class','axis').text(d=>d.length>30?d.slice(0,28)+'…':d)}'''

html2=re.sub(r'function map\(\)\{.*?\}\nfunction heatmap',new_map+'\nfunction heatmap',html,count=1,flags=re.S)
html2=re.sub(r'function heatmap\(\)\{.*?\}\nfunction topics',new_heat+'\nfunction topics',html2,count=1,flags=re.S)
if html2==html:
    raise SystemExit('Dashboard functions were not found; refusing to write a partial patch')
HTML.write_text(html2,encoding='utf-8')
print('Patched dashboard JSON with country × species counts and fixed map/heatmap rendering.')
