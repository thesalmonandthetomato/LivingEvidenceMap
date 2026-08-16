#!/usr/bin/env python3
"""Final dashboard presentation patch.

The database presentation is restored to the approved working version. Topic
hierarchy/heatmap presentation is handled here separately and does not alter
master data.
"""
from pathlib import Path
import re
P=Path('docs/index.html'); html=P.read_text(encoding='utf-8')
# ---------------- Database: restore approved presentation ----------------
old_section=re.search(r'<section class="section" id="database">.*?</section></main>',html,re.S)
new_section='''<section class="section" id="database"><h2>Database</h2><p class="sub">Filters selected above are applied here.</p><div class="controls"><input id="q" placeholder="Search title or abstract…"><label>Species <select id="tableSpecies"><option value="__all__">All species</option></select></label><label>Country <select id="tableCountry"><option value="__all__">All countries</option></select></label><label>Topic <select id="tableTopic"><option value="__all__">All topics</option></select></label><label>Records <select id="pageSize"><option>10</option><option>20</option><option selected>50</option></select></label><button id="clear">Clear filters</button></div><div id="dbCount" class="sub"></div><div class="table-wrap"><table class="table"><thead><tr><th data-sort="title">Title &amp; summary ↕</th><th data-sort="year">Year ↕</th><th data-sort="authors">Authors ↕</th><th data-sort="publication">Journal / volume / pages ↕</th><th data-sort="topics">Topics ↕</th></tr></thead><tbody id="tbody"></tbody></table></div><div class="pager"><button id="prev">Previous</button><span id="page"></span><button id="next">Next</button></div></section></main>'''
if old_section: html=html[:old_section.start()]+new_section+html[old_section.end():]
# Restore approved database CSS for citation/summary/DOI display.
css='.citation{min-width:260px}.citation .muted{margin:2px 0}.citation a{color:var(--ink);font-weight:650}.citation-doi{word-break:break-all}.summary{max-width:680px}.record-doi{font-size:11px;margin-top:3px}.record-doi a{color:var(--mid)}.topic-pill{cursor:default}'
if '.summary{max-width:' not in html: html=html.replace('</style>',css+'</style>',1)
# Hierarchical topic filtering: exact branch or any descendant.
html=html.replace("function topicMatches(r){if(!state.topic)return true;return r.topics.includes(state.topic)||(r.topic_paths||[]).some(p=>p.includes(state.topic))}","function topicMatches(r){const sel=state.topic;if(!sel)return true;const paths=(r.topic_paths||[]).map(p=>p.join(' > '));return paths.some(p=>p===sel||p.startsWith(sel+' > '))}")
# Replace the database table renderer with the approved compact citation layout.
start=html.index('function scholarUrl('); end=html.index('function showTip(',start)
table_js=r'''function scholarUrl(t){return 'https://scholar.google.co.uk/scholar?hl=en&as_sdt=0%2C5&q='+String(t||'').replace(/[^\p{L}\p{N}\s]/gu,'').trim().replace(/\s+/g,'+')}
function recordUrl(r){if(r.doi)return 'https://doi.org/'+encodeURIComponent(String(r.doi).replace(/^https?:\/\/(doi\.org\/)?/i,''));if(r.lens_url)return r.lens_url;return scholarUrl(r.title)}
function truncateAbstract(s,n=220){const text=String(s??'').trim();if(text.length<=n)return text;return text.slice(0,n+1).replace(/\s+\S*$/,'').trim()+'…'}
function countryLabel(c){return (D.country_name_by_iso3||{})[String(c).toUpperCase()]||c}
function formatAuthors(s){const raw=String(s||'').trim();if(!raw)return '';const a=raw.split(/\s*;\s*|\s*\|\s*|\s+and\s+|\s*,\s*(?=[A-Z][^,;|]*\b(?:[A-Z]\.\s*)?[A-Za-z'’-]+)/).map(x=>x.trim()).filter(Boolean);if(a.length<=2)return a.join(' and ');return a[0]+' et al.'}
function publication(r){return [r.journal,r.volume,r.pages?`pp. ${r.pages}`:''].filter(Boolean).join(' · ')}
function topicPathHtml(r){const paths=(r.topic_paths||[]).map(p=>p.join(' > '));return paths.map(path=>`<span class="pill topic-pill" title="${esc((D.topic_definitions||{})[path]||'')}">${esc(path)}</span>`).join('')}
function table(){let a=recordsFor(),k=state.sort,d=state.dir==='desc'?-1:1;a.sort((x,y)=>{const xt=!String(x.title||'').trim()||String(x.title).trim().toLowerCase()==='untitled',yt=!String(y.title||'').trim()||String(y.title).trim().toLowerCase()==='untitled';if(xt!==yt)return xt?1:-1;const vx=k==='authors'?formatAuthors(x.authors):k==='publication'?publication(x):k==='topics'?(x.topic_paths||[]).map(p=>p.join(' > ')).join('; '):(x[k]??''),vy=k==='authors'?formatAuthors(y.authors):k==='publication'?publication(y):k==='topics'?(y.topic_paths||[]).map(p=>p.join(' > ')).join('; '):(y[k]??'');return String(vx).localeCompare(String(vy),undefined,{numeric:true,sensitivity:'base'})*d});const pages=Math.max(1,Math.ceil(a.length/state.size));state.page=Math.min(state.page,pages);const z=a.slice((state.page-1)*state.size,state.page*state.size);tbody.innerHTML=z.map(r=>{const doi=r.doi?`<div class="record-doi"><a href="${esc('https://doi.org/'+String(r.doi).replace(/^https?:\/\/(doi\.org\/)?/i,''))}" target="_blank" rel="noopener">DOI: ${esc(r.doi)}</a></div>`:'';return `<tr><td><a href="${esc(recordUrl(r))}" target="_blank" rel="noopener"><b>${esc(r.title||'Untitled')}</b></a><div class="muted summary">${esc(truncateAbstract(r.abstract))}</div>${doi}</td><td>${r.year===''?'':esc(String(parseInt(r.year,10)))}</td><td>${esc(formatAuthors(r.authors))}</td><td>${esc(publication(r))}</td><td>${topicPathHtml(r)}</td></tr>`}).join('');const first=a.length?(state.page-1)*state.size+1:0,last=Math.min(state.page*state.size,a.length);dbCount.textContent=`${fmt(a.length)} matching records${a.length?` · showing ${fmt(first)}–${fmt(last)}`:''}`;page.textContent=`${state.page} / ${pages}`;prev.disabled=state.page<=1;next.disabled=state.page>=pages} 
'''
html=html[:start]+table_js+html[end:]
# Restore page-size state and event binding, and use full country names in the dropdown.
html=html.replace("function syncControls(){tableSpecies.value=state.species;tableCountry.value=state.country;tableTopic.value=state.topic||'__all__';q.value=state.q}","function syncControls(){tableSpecies.value=state.species;tableCountry.value=state.country;tableTopic.value=state.topic||'__all__';q.value=state.q;pageSize.value=String(state.size)}")
html=html.replace("Object.keys(D.country_iso3_counts||{}).forEach(c=>tableCountry.add(new Option(c,c)));", "Object.keys(D.country_iso3_counts||{}).forEach(c=>tableCountry.add(new Option(countryLabel(c),c)));")
html=html.replace("tableTopic.onchange=()=>setFilter({topic:tableTopic.value==='__all__'?null:tableTopic.value});q.oninput", "tableTopic.onchange=()=>setFilter({topic:tableTopic.value==='__all__'?null:tableTopic.value});pageSize.onchange=()=>{state.size=Number(pageSize.value);state.page=1;table()};q.oninput")
# ---------------- Topic hierarchy presentation ----------------
html=re.sub(r'\.tree>ul\{[^}]*\}', '.tree>ul{padding:0;display:block}', html, count=1)
if '.tree>ul>li{display:block' not in html:
    html=html.replace('</style>', '.tree>ul>li{display:block;margin:0 0 14px;background:#fff;border:1px solid var(--line);border-radius:16px;padding:14px 16px 12px;box-shadow:0 3px 12px #2c454a10;border-left:5px solid var(--mid)}.tree>ul>li:nth-child(4n+2){border-left-color:var(--sand)}.tree>ul>li:nth-child(4n+3){border-left-color:var(--coral)}.tree>ul>li:nth-child(4n+4){border-left-color:var(--pale)}</style>',1)
if '.tree-description{' not in html:
    html=html.replace('</style>', '.tree-description{display:block;margin:7px 0 10px 34px;padding:8px 12px;background:#f4f7f6;border-left:3px solid var(--mid);border-radius:8px;color:#53676b;font-size:12px;line-height:1.5;max-width:900px}.tree-description::before{content:"DESCRIPTION";display:block;font-size:9px;font-weight:800;letter-spacing:.08em;color:var(--mid);margin-bottom:3px}</style>',1)
P.write_text(html,encoding='utf-8')
print('Restored approved database table and controls; retained separate topic-hierarchy styling')