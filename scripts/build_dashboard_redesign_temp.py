#!/usr/bin/env python3
"""Build the temporary dashboard redesign from the current approved dashboard HTML.

This does not alter docs/index.html. It writes docs/dashboard-redesign-temp.html,
which is deployed only by the temporary preview workflow.
"""
from pathlib import Path
import re

SRC = Path("docs/index.html")
OUT = Path("docs/dashboard-redesign-temp.html")
html = SRC.read_text(encoding="utf-8")

# Temporary page uses a separate data payload built from the corrected master.
html = html.replace("dashboard.json?'+Date.now()", "dashboard-redesign-temp.json?'+Date.now()")

# Do not load the production radial patch; the preview has its own renderer.
html = html.replace('<script src="./topic-radial.js"></script>', '')

extra_css = r'''
.temp-banner{width:min(1450px,92vw);margin:14px auto 0;background:#fff4ef;border:1px solid #f0c8b8;border-radius:10px;padding:10px 14px;color:var(--ink);font-size:13px}
.chart-host{width:100%;overflow:hidden}.chart-host svg{display:block;width:100%;height:auto}
.chart-axis text{fill:var(--mid);font-size:11px}.chart-axis path,.chart-axis line{stroke:#d9e2e1}
.legend{display:flex;gap:10px 16px;flex-wrap:wrap;margin:8px 0 0}.legend-item{display:inline-flex;align-items:center;gap:6px;font-size:12px;color:var(--ink)}.legend-swatch{width:13px;height:13px;border-radius:2px;display:inline-block}
.heat-context{font-size:12px;color:var(--mid);margin-left:2px}.heat-label{cursor:pointer;fill:var(--ink);font-size:11px}.heat-label.has-children{font-weight:700;text-decoration:underline;text-underline-offset:3px}
.topic-radial{min-height:0!important;width:min(620px,100%)!important;height:auto!important;max-width:620px!important;max-height:70vh!important;aspect-ratio:1/1;margin:0 auto;overflow:hidden!important;display:block!important}
.topic-radial svg{display:block!important;width:100%!important;height:100%!important;max-width:620px!important;max-height:70vh!important}
.topic-radial-arc{cursor:pointer;stroke:#fff;stroke-width:1.1px}.topic-radial-arc:hover{stroke:var(--ink);stroke-width:1.8px}
.database-species-cell{white-space:normal;min-width:145px}.database-species-cell .pill{margin:2px 2px 2px 0}
'''
html = html.replace("</style>", extra_css + "</style>", 1)
html = html.replace("</header><main", '</header><div class="temp-banner"><b>Temporary redesign preview.</b> Built from the current approved dashboard presentation and the corrected master dataset. The live dashboard is unchanged.</div><main', 1)

# Choropleth stays first. Insert the two new summaries immediately after it,
# before the existing heatmap section.
insert_marker = '<section class="section"><h2>Evidence by species × topic'
new_sections = r'''
<section class="section"><h2>Records by publication year</h2><p class="sub">Annual record count. Use the selector to show total records, or split each year by focal farmed species or high-level topic.</p><div class="controls"><label>Block bars by <select id="yearGroup"><option value="none">Nothing</option><option value="species">Species</option><option value="topic">High-level topic</option></select></label></div><div id="yearChart" class="chart-host"></div><div id="yearLegend" class="legend"></div></section>
<section class="section"><h2>Topic-assignment frequency by species</h2><p class="sub">High-level topic assignments split by focal farmed species. Counts are unique records within each species × topic combination. Click a segment to filter the database to that species and topic.</p><div id="topicSpeciesChart" class="chart-host"></div><div id="topicSpeciesLegend" class="legend"></div></section>
'''
if insert_marker not in html:
    raise SystemExit("Could not locate heatmap section")
html = html.replace(insert_marker, new_sections + insert_marker, 1)

# Replace the heatmap UI with drill-down labels and a reset button.
heat_re = re.compile(r'<section class="section"><h2>Evidence by species × topic</h2>.*?</section>', re.S)
heat_section = r'''<section class="section"><h2>Evidence by species × topic</h2><p class="sub">Click a topic label to move down one hierarchy level within that branch. Click a cell to reset any existing database filters and show only that species × topic combination.</p><div class="controls"><label>Species <select id="heatSpecies"><option value="__all__">All species</option></select></label><button id="heatReset" type="button">Reset topic view</button><span id="heatContext" class="heat-context">Showing high-level topics</span><span style="display:none"><select id="heatTop"><option value="__all__">All topics</option></select><select id="heatLevel"><option value="1">1</option></select><select id="heatParent"><option value="__all__">All top-level topics</option></select><select id="heatLimit"><option selected>60</option></select><button id="heatBack" type="button"></button></span></div><div class="heat-scroll"><div id="heatmap"></div></div></section>'''
html, n = heat_re.subn(heat_section, html, count=1)
if n != 1:
    raise SystemExit("Could not replace heatmap section")

# Tighten the hierarchy copy and constrain it to the viewport.
hier_re = re.compile(r'<section class="section"><h2>Topic hierarchy</h2>.*?<div id="topicRadial" class="topic-radial"></div></section>', re.S)
hier_section = r'''<section class="section"><h2>Topic hierarchy</h2><p class="sub">Radial hierarchy of topics. Colour spans the dashboard palette across the high-level branches. Hover for counts; click any segment to reset existing database filters and filter to that hierarchy level.</p><div class="topic-radial-controls"><button id="topicRadialReset" type="button">Reset highlight</button></div><div id="topicRadial" class="topic-radial"></div></section>'''
html, n = hier_re.subn(hier_section, html, count=1)
if n != 1:
    raise SystemExit("Could not replace topic hierarchy section")

addon = r'''
<script>
(function(){
'use strict';

const SPECIES_COLOURS={
  'Atlantic salmon':'#e55634','Chinook salmon':'#2c454a','Chum salmon':'#3e5b60','Coho salmon':'#4f6d73',
  'Masu salmon':'#63838a','Pink salmon':'#78999f','Sockeye salmon':'#8fa9ad','Rainbow trout':'#a8bdbe','Unspecified species':'#e2b8a2'
};
const TOPIC_ORDER=['Production','Environment','Methods','Industry and governance','Product','People and society','Inputs and resources'];
const TOPIC_COLOURS={'Production':'#2c454a','Environment':'#577c84','Methods':'#8fa8aa','Industry and governance':'#b8b4ac','Product':'#e2b8a2','People and society':'#ff9d78','Inputs and resources':'#e55634'};
let heatBranch=null, topicTree=null;

function recordId(r,i){return String(r.record_id??r.id??r.lens_id??r.doi??r.title??i)}
function splitPath(p){return Array.isArray(p)?p.map(x=>String(x).trim()).filter(Boolean):String(p||'').split(/\s*>\s*/).map(x=>x.trim()).filter(Boolean)}
function rootTopics(r){const s=new Set();(r.topic_paths||[]).forEach(p=>{const a=splitPath(p);if(a.length)s.add(a[0])});return [...s]}
function displaySpecies(s){return s==='Unspecified species'?'Unspecified salmon':s}
function allSpecies(){
  const canonical=['Atlantic salmon','Chinook salmon','Chum salmon','Coho salmon','Masu salmon','Pink salmon','Sockeye salmon','Rainbow trout','Unspecified species'];
  const have=new Set();(D.records||[]).forEach(r=>(r.species||[]).forEach(s=>have.add(s)));
  return canonical.filter(s=>have.has(s)).concat([...have].filter(s=>!canonical.includes(s)).sort());
}
function allRoots(){
  const have=new Set();(D.records||[]).forEach(r=>rootTopics(r).forEach(t=>have.add(t)));
  return TOPIC_ORDER.filter(t=>have.has(t)).concat([...have].filter(t=>!TOPIC_ORDER.includes(t)).sort());
}
function legend(host,items,colours){
  host.innerHTML=items.map(x=>'<span class="legend-item"><span class="legend-swatch" style="background:'+colours[x]+'"></span>'+esc(displaySpecies(x))+'</span>').join('');
}

// Figure-originated filtering must replace, not accumulate, database filters.
function replaceFilter(x,doJump=true){
  state.species='__all__'; state.country='__all__'; state.topic=null; state.q=''; state.page=1;
  Object.assign(state,x);
  syncControls(); table();
  if(doJump) jump();
}
window.replaceFilter=replaceFilter;

function renderYear(){
  const host=d3.select('#yearChart');host.selectAll('*').remove();
  const mode=document.getElementById('yearGroup').value;
  const recs=(D.records||[]).filter(r=>Number.isFinite(+r.year)&&+r.year>1800&&+r.year<2100);
  if(!recs.length)return;
  const min=d3.min(recs,r=>+r.year),max=d3.max(recs,r=>+r.year),years=d3.range(min,max+1);
  let cats,colours;
  if(mode==='species'){cats=allSpecies();colours=SPECIES_COLOURS}
  else if(mode==='topic'){cats=allRoots();colours=TOPIC_COLOURS}
  else{cats=['Records'];colours={Records:'#e55634'}}
  const by=new Map(years.map(y=>[y,new Map()]));
  recs.forEach((r,i)=>{
    const y=+r.year,id=recordId(r,i),vals=mode==='species'?(r.species||[]):mode==='topic'?rootTopics(r):['Records'];
    [...new Set(vals)].forEach(c=>{if(!by.get(y).has(c))by.get(y).set(c,new Set());by.get(y).get(c).add(id)});
  });
  const rows=years.map(y=>{const o={year:y};cats.forEach(c=>o[c]=(by.get(y).get(c)||new Set()).size);return o});
  const W=1120,H=420,ml=65,mr=20,mt=18,mb=55;
  const svg=host.append('svg').attr('viewBox',`0 0 ${W} ${H}`).attr('preserveAspectRatio','xMidYMid meet');
  const x=d3.scaleBand().domain(years).range([ml,W-mr]).padding(.12);
  const stack=d3.stack().keys(cats)(rows);
  const ymax=d3.max(stack[stack.length-1]||[],d=>d[1])||1;
  const y=d3.scaleLinear().domain([0,ymax]).nice().range([H-mb,mt]);
  svg.append('g').attr('class','chart-axis').attr('transform',`translate(0,${H-mb})`).call(d3.axisBottom(x).tickValues(years.filter(v=>v%10===0||v===min||v===max)).tickSizeOuter(0));
  svg.append('g').attr('class','chart-axis').attr('transform',`translate(${ml},0)`).call(d3.axisLeft(y).ticks(6));
  svg.append('text').attr('x',W/2).attr('y',H-8).attr('text-anchor','middle').attr('fill','#2c454a').attr('font-weight',650).text('Publication year');
  svg.append('text').attr('transform','rotate(-90)').attr('x',-(H-mb+mt)/2).attr('y',17).attr('text-anchor','middle').attr('fill','#2c454a').attr('font-weight',650).text('Number of records');
  svg.selectAll('g.year-layer').data(stack).join('g').attr('class','year-layer').attr('fill',d=>colours[d.key]||'#577c84').selectAll('rect').data(d=>d.map(v=>{v.key=d.key;return v})).join('rect')
    .attr('x',d=>x(d.data.year)).attr('y',d=>y(d[1])).attr('height',d=>Math.max(0,y(d[0])-y(d[1]))).attr('width',x.bandwidth())
    .on('mousemove',(e,d)=>showTip(e,`<b>${esc(String(d.data.year))}</b><br>${esc(displaySpecies(d.key))}: ${fmt(d[1]-d[0])}`)).on('mouseleave',hideTip);
  legend(document.getElementById('yearLegend'),cats,colours);
}

function renderTopicSpecies(){
  const host=d3.select('#topicSpeciesChart');host.selectAll('*').remove();
  const species=allSpecies(),topics=allRoots(),sets=new Map();
  (D.records||[]).forEach((r,i)=>{
    const id=recordId(r,i);
    [...new Set(r.species||[])].forEach(s=>rootTopics(r).forEach(t=>{
      const k=t+'|||'+s;if(!sets.has(k))sets.set(k,new Set());sets.get(k).add(id)
    }));
  });
  const rows=topics.map(t=>{const o={topic:t};species.forEach(s=>o[s]=(sets.get(t+'|||'+s)||new Set()).size);return o});
  const stack=d3.stack().keys(species)(rows),totals=rows.map(r=>species.reduce((a,s)=>a+r[s],0));
  const W=1120,H=Math.max(360,topics.length*58+90),ml=245,mr=85,mt=18,mb=55;
  const svg=host.append('svg').attr('viewBox',`0 0 ${W} ${H}`).attr('preserveAspectRatio','xMidYMid meet');
  const y=d3.scaleBand().domain(topics).range([mt,H-mb]).padding(.30);
  const x=d3.scaleLinear().domain([0,d3.max(totals)||1]).nice().range([ml,W-mr]);
  svg.append('g').attr('class','chart-axis').attr('transform',`translate(0,${H-mb})`).call(d3.axisBottom(x).ticks(5));
  svg.append('g').attr('class','chart-axis').attr('transform',`translate(${ml},0)`).call(d3.axisLeft(y).tickSize(0).tickPadding(10)).call(g=>{g.select('.domain').remove();g.selectAll('text').attr('font-size',13).attr('font-weight',650).attr('fill','#2c454a')});
  svg.append('text').attr('x',(ml+W-mr)/2).attr('y',H-8).attr('text-anchor','middle').attr('fill','#577c84').attr('font-size',13).text('Records / species-record observations');
  svg.selectAll('g.topic-layer').data(stack).join('g').attr('class','topic-layer').attr('fill',d=>SPECIES_COLOURS[d.key]||'#577c84').selectAll('rect').data(d=>d.map(v=>{v.key=d.key;return v})).join('rect')
    .attr('x',d=>x(d[0])).attr('y',d=>y(d.data.topic)).attr('width',d=>Math.max(0,x(d[1])-x(d[0]))).attr('height',y.bandwidth()).style('cursor','pointer')
    .on('click',(e,d)=>replaceFilter({species:d.key,topic:d.data.topic}))
    .on('mousemove',(e,d)=>showTip(e,`<b>${esc(d.data.topic)}</b><br>${esc(displaySpecies(d.key))}: ${fmt(d[1]-d[0])} records<br>Click to filter database`)).on('mouseleave',hideTip);
  svg.selectAll('text.total').data(rows).join('text').attr('class','total').attr('x',(d,i)=>x(totals[i])+7).attr('y',d=>y(d.topic)+y.bandwidth()/2+4).attr('fill','#2c454a').attr('font-size',12).text((d,i)=>fmt(totals[i]));
  legend(document.getElementById('topicSpeciesLegend'),species,SPECIES_COLOURS);
}

function makeTree(){
  const root={name:'All topics',key:'',ids:new Set(),children:new Map()};
  (D.records||[]).forEach((r,i)=>{
    const id=recordId(r,i);root.ids.add(id);
    (r.topic_paths||[]).forEach(p=>{
      const a=splitPath(p);let node=root,key='';
      a.forEach(name=>{key=key?key+' > '+name:name;if(!node.children.has(name))node.children.set(name,{name,key,ids:new Set(),children:new Map()});node=node.children.get(name);node.ids.add(id)});
    });
  });
  return root;
}
function nodeAt(path){
  let node=topicTree;if(!path)return node;
  for(const name of path.split(' > ')){node=node.children.get(name);if(!node)return null}
  return node;
}

function renderHeat(){
  const el=d3.select('#heatmap');el.selectAll('*').remove();if(!topicTree)topicTree=makeTree();
  const parent=nodeAt(heatBranch);
  const nodes=parent?[...parent.children.values()].sort((a,b)=>b.ids.size-a.ids.size||a.name.localeCompare(b.name)):[];
  const selected=document.getElementById('heatSpecies').value,species=selected==='__all__'?allSpecies():[selected],counts=new Map();
  (D.records||[]).forEach((r,i)=>{
    const id=recordId(r,i);
    [...new Set(r.species||[])].forEach(s=>{
      if(!species.includes(s))return;
      (r.topic_paths||[]).forEach(p=>{
        const full=splitPath(p).join(' > ');
        nodes.forEach(n=>{if(full===n.key||full.startsWith(n.key+' > ')){const k=s+'|||'+n.key;if(!counts.has(k))counts.set(k,new Set());counts.get(k).add(id)}})
      });
    });
  });
  const cw=128,ch=36,left=195,bottom=210,W=Math.max(940,left+nodes.length*cw+25),H=50+species.length*ch+bottom;
  const svg=el.append('svg').attr('width',W).attr('height',H);
  const max=d3.max(species,s=>d3.max(nodes,n=>(counts.get(s+'|||'+n.key)||new Set()).size))||1;
  const colour=d3.scaleSequential(d3.interpolateRgbBasis(['#f0f3f2','#a8bdbe','#577c84','#2c454a','#e55634'])).domain([1,max]);
  species.forEach((s,i)=>nodes.forEach((n,j)=>{
    const v=(counts.get(s+'|||'+n.key)||new Set()).size;
    svg.append('rect').attr('x',left+j*cw).attr('y',40+i*ch).attr('width',cw).attr('height',ch).attr('fill',v===0?'#f8f9f8':colour(v)).attr('class','heat-cell')
      .on('click',()=>replaceFilter({species:s,topic:n.key}))
      .on('mousemove',e=>showTip(e,`<b>${esc(displaySpecies(s))}</b><br>${esc(n.key)}<br>${fmt(v)} unique records<br>Click to filter database`)).on('mouseleave',hideTip);
  }));
  svg.selectAll('.slabel').data(species).join('text').attr('x',left-8).attr('y',(s,i)=>40+i*ch+23).attr('text-anchor','end').attr('class','axis').text(displaySpecies);
  svg.selectAll('.tlabel').data(nodes).join('text').attr('transform',(n,i)=>`translate(${left+i*cw+cw/2},${48+species.length*ch}) rotate(-55)`).attr('text-anchor','end')
    .attr('class',n=>'heat-label'+(n.children.size?' has-children':'')).text(n=>n.name+(n.children.size?' ▾':''))
    .on('click',(e,n)=>{if(n.children.size){heatBranch=n.key;renderHeat()}})
    .on('mousemove',(e,n)=>showTip(e,n.children.size?`<b>${esc(n.name)}</b><br>Click to show the next hierarchy level`:`<b>${esc(n.name)}</b><br>No lower level`)).on('mouseleave',hideTip);
  document.getElementById('heatContext').textContent=heatBranch?'Showing children of: '+heatBranch:'Showing high-level topics';
}

function renderRadial(){
  const el=d3.select('#topicRadial');el.selectAll('*').remove();if(!topicTree)topicTree=makeTree();
  function conv(n){return {name:n.name,key:n.key,count:n.ids.size,children:[...n.children.values()].sort((a,b)=>b.ids.size-a.ids.size).map(conv)}}
  const data=conv(topicTree),W=600,H=600,R=282,h=d3.hierarchy(data);
  h.sum(d=>d.children&&d.children.length?0:d.count);d3.partition().size([2*Math.PI,R])(h);
  const roots=allRoots(),fallback=d3.quantize(d3.interpolateRgbBasis(['#577c84','#a8bdbe','#e2b8a2','#ff9d78','#e55634']),Math.max(2,roots.length));
  const rootColour={};roots.forEach((t,i)=>rootColour[t]=TOPIC_COLOURS[t]||fallback[i]);
  function top(d){const a=d.ancestors().reverse();return a.length>1?a[1].data.name:d.data.name}
  function fill(d){const c=d3.color(rootColour[top(d)]||'#577c84');return d.depth===1?c.formatHex():c.brighter(Math.min(1.15,(d.depth-1)*.38)).formatHex()}
  const svg=el.append('svg').attr('viewBox',`0 0 ${W} ${H}`).attr('preserveAspectRatio','xMidYMid meet');
  const g=svg.append('g').attr('transform',`translate(${W/2},${H/2})`);
  const arc=d3.arc().startAngle(d=>d.x0).endAngle(d=>d.x1).innerRadius(d=>d.y0).outerRadius(d=>Math.max(d.y0+1,d.y1-1.1));
  const paths=g.selectAll('path').data(h.descendants().filter(d=>d.depth>0)).join('path').attr('class','topic-radial-arc').attr('d',arc).attr('fill',fill)
    .on('mousemove',(e,d)=>showTip(e,`<b>${esc(d.data.name)}</b><br>${fmt(d.data.count)} unique records<br>${esc(d.data.key)}<br>Click to filter database`)).on('mouseleave',hideTip)
    .on('click',(e,d)=>{e.stopPropagation();replaceFilter({topic:d.data.key})});
  const centre=g.append('g');centre.append('circle').attr('r',86).attr('fill','#fff').attr('stroke','#d9e2e1');
  centre.append('text').attr('text-anchor','middle').attr('y',-7).attr('font-weight',700).attr('fill','#2c454a').text('All topics');
  centre.append('text').attr('text-anchor','middle').attr('y',24).attr('font-size',25).attr('font-weight',750).attr('fill','#2c454a').text(fmt(data.count));
  document.getElementById('topicRadialReset').onclick=()=>paths.attr('opacity',1);
}

function installSpeciesColumn(){
  const apply=()=>{
    const tableEl=document.querySelector('#database table.table'),head=tableEl&&tableEl.querySelector('thead tr'),body=tableEl&&tableEl.querySelector('tbody');
    if(!head||!body)return;
    if(!head.querySelector('th[data-species-column]')){const th=document.createElement('th');th.textContent='Species';th.setAttribute('data-species-column','true');head.insertBefore(th,head.children[1]||null)}
    body.querySelectorAll('tr').forEach(row=>{
      if(row.querySelector('td[data-species-column]'))return;
      const first=(row.children[0]?.textContent||'').toLowerCase();
      const rec=(D.records||[]).find(r=>{const t=String(r.title||'').toLowerCase();return t&&first.includes(t)});
      const td=document.createElement('td');td.className='database-species-cell';td.setAttribute('data-species-column','true');
      td.innerHTML=((rec&&rec.species)||[]).map(s=>'<span class="pill">'+esc(displaySpecies(s))+'</span>').join('');
      row.insertBefore(td,row.children[1]||null);
    });
  };
  apply();new MutationObserver(apply).observe(document.getElementById('database'),{childList:true,subtree:true});
}

function overrideMapClick(){
  // Re-render the production choropleth with replacement-filter semantics.
  window.map=function(){
    const el=d3.select('#map');el.selectAll('*').remove();const sp=state.species,vals=sp==='__all__'?D.country_iso3_counts:(D.country_iso3_species_counts?.[sp]||{}),w=el.node().clientWidth||900,h=500,svg=el.append('svg').attr('width','100%').attr('viewBox',`0 0 ${w} ${h}`),path=d3.geoPath(d3.geoNaturalEarth1().fitSize([w,h],{type:'Sphere'})),max=d3.max(Object.values(vals))||1,color=d3.scaleSequential(d3.interpolateRgbBasis([palette[2],palette[1],palette[0],palette[5]])).domain([0,max]);
    d3.json('https://cdn.jsdelivr.net/npm/world-atlas@2/countries-110m.json').then(world=>{
      const features=topojson.feature(world,world.objects.countries).features;
      svg.selectAll('path').data(features).join('path').attr('d',path).attr('fill',d=>{const iso=D.map_id_to_iso3?.[String(d.id)];return color(vals[iso]||0)}).attr('stroke','#fff').attr('stroke-width','.5')
        .on('mousemove',(e,d)=>{const iso=D.map_id_to_iso3?.[String(d.id)];showTip(e,`<b>${esc(d.properties.name||'Country')}</b><br>${fmt(vals[iso]||0)} records`)})
        .on('mouseleave',hideTip).on('click',(e,d)=>{const iso=D.map_id_to_iso3?.[String(d.id)];if(iso&&(vals[iso]||0)>0)replaceFilter({species:sp,country:iso})});
    }).catch(()=>el.append('p').text('Map data could not be loaded.'));
  };
  map();
}

function boot(){
  if(typeof D==='undefined'||!D||!Array.isArray(D.records)){setTimeout(boot,100);return}
  window.D=D;topicTree=makeTree();
  overrideMapClick();
  document.getElementById('yearGroup').onchange=renderYear;
  document.getElementById('heatSpecies').onchange=renderHeat;
  document.getElementById('heatReset').onclick=()=>{heatBranch=null;renderHeat()};
  renderYear();renderTopicSpecies();renderHeat();renderRadial();installSpeciesColumn();
}
setTimeout(boot,250);
})();
</script>
'''
html = html.replace("</body>", addon + "</body>", 1)
OUT.write_text(html, encoding="utf-8")
print(f"Wrote {OUT}")
