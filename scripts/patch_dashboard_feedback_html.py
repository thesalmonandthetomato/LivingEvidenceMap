#!/usr/bin/env python3
"""Final dashboard presentation patch: project text, database, species ordering and topic descriptions."""
from pathlib import Path
P=Path('docs/index.html'); html=P.read_text(encoding='utf-8')
INTRO='''<p class="project-description">The Living Evidence Map is a scoping review of research articles on aquaculture of all salmon species, including Atlantic and Pacific salmon and rainbow trout, across all production stages. The map was originally populated by manual screening of &gt;19,000 records and is now maintained using validated machine screening and content annotation, supported by LLMs (OpenAI GPT-5-mini). For further information on the wider project, see <a href="https://www.thesalmonandthetomato.org" style="color:#fff">The Salmon and the Tomato [www.thesalmonandthetomato.org]</a>. This project was coordinated by Dr Neal Haddaway.</p>'''
old_intro='<p>An interactive view of the living evidence map. The map is updated automatically, with human oversight on a weekly basis. Data are sourced from <a href="https://www.lens.org" style="color:#fff">www.lens.org</a>.</p>'
if old_intro in html: html=html.replace(old_intro,INTRO,1)
html=html.replace('<h2>Master database</h2>','<h2>Database</h2>',1).replace('Search title, abstract or record ID…','Search title or abstract…',1)
old_head='<th data-sort="record_id">Record ↕</th><th data-sort="title">Title ↕</th><th data-sort="year">Year ↕</th><th data-sort="species">Species ↕</th><th data-sort="countries">Country ↕</th><th data-sort="topics">Topics ↕</th><th>Citation</th>'
new_head='<th data-sort="title">Title ↕</th><th data-sort="year">Year ↕</th><th data-sort="species">Species ↕</th><th data-sort="countries">Country ↕</th><th>Author</th><th>Journal</th><th>Volume</th><th>Pages</th><th>DOI</th><th>Topics</th>'
if old_head in html: html=html.replace(old_head,new_head,1)

# Grouped species filter: Atlantic salmon, rainbow trout, other salmon, unspecified salmon.
rs='function recordsFor()'
if rs in html:
    s=html.index(rs); e=html.index('\nfunction ',s+10)
    fn=r'''function speciesGroup(s){
  if(s==='Atlantic salmon'||s==='Rainbow trout')return s;
  if(s==='Unspecified species')return 'Unspecified salmon';
  return 'Other salmon';
}
function recordMatchesSpecies(r,selected){return selected==='__all__'||r.species.some(s=>speciesGroup(s)===selected)}
function recordsFor(){return D.records.filter(r=>recordMatchesSpecies(r,state.species)&&(state.country==='__all__'||r.iso3.includes(state.country))&&topicMatches(r)&&(!state.q||[r.title,r.abstract,r.year,...r.species,...r.countries,...r.topics].join(' ').toLowerCase().includes(state.q.toLowerCase())))}'''
    html=html[:s]+fn+html[e:]

# Database table and requested metadata.
s='function table(){'; e='function showTip('; start=html.index(s); end=html.index(e,start)
table_fn=r'''function truncateAbstract(s,n=180){const text=String(s??'').trim();if(text.length<=n)return text;const cut=text.slice(0,n+1).replace(/\s+\S*$/,'').trim();return cut+'…'}
function countryLabel(c){return (D.country_name_by_iso3||{})[String(c).toUpperCase()]||c}
function topicDescription(path){return (D.topic_definitions||{})[path]||''}
function table(){
 let a=recordsFor(),k=state.sort,d=state.dir==='desc'?-1:1;
 a.sort((x,y)=>{const xt=!String(x.title||'').trim()||String(x.title).trim().toLowerCase()==='untitled',yt=!String(y.title||'').trim()||String(y.title).trim().toLowerCase()==='untitled';if(xt!==yt)return xt?1:-1;const vx=k==='species'?x.species.map(speciesGroup).join('; '):k==='countries'?x.countries.join('; '):k==='topics'?x.topics.join('; '):(x[k]??''),vy=k==='species'?y.species.map(speciesGroup).join('; '):k==='countries'?y.countries.join('; '):k==='topics'?y.topics.join('; '):(y[k]??'');return String(vx).localeCompare(String(vy),undefined,{numeric:true,sensitivity:'base'})*d});
 const pages=Math.max(1,Math.ceil(a.length/state.size));state.page=Math.min(state.page,pages);const z=a.slice((state.page-1)*state.size,state.page*state.size);
 tbody.innerHTML=z.map(r=>{const title=r.title||'Untitled',paths=(r.topic_paths||[]).map(p=>p.join(' > ')),topicHtml=paths.map(path=>`<span class="pill topic-pill" title="${esc(topicDescription(path))}">${esc(path)}</span>`).join(''),countries=(r.countries||[]).map(c=>`<span class="country-label" title="${esc(countryLabel(c))}">${esc(c)}</span>`).join(', '),doi=r.doi?`<a href="${esc('https://doi.org/'+String(r.doi).replace(/^https?:\/\/(doi\.org\/)?/i,''))}" target="_blank" rel="noopener">${esc(r.doi)}</a>`:'';return `<tr><td><a href="${esc(recordUrl(r))}" target="_blank" rel="noopener"><b>${esc(title)}</b></a><div class="muted">${esc(truncateAbstract(r.abstract))}</div></td><td>${esc(r.year)}</td><td>${r.species.map(s=>`<span class="pill">${esc(s==='Unspecified species'?'Unspecified salmon':s)}</span>`).join('')}</td><td>${countries}</td><td>${esc(r.authors||'')}</td><td>${esc(r.journal||'')}</td><td>${esc(r.volume||'')}</td><td>${esc(r.pages||'')}</td><td class="citation-doi">${doi}</td><td>${topicHtml}</td></tr>`}).join('');
 const first=a.length?(state.page-1)*state.size+1:0,last=Math.min(state.page*state.size,a.length);dbCount.textContent=`${fmt(a.length)} matching records${a.length?` · showing ${fmt(first)}–${fmt(last)}`:''}`;page.textContent=`${state.page} / ${pages}`;prev.disabled=state.page<=1;next.disabled=state.page>=pages;
}'''
html=html[:start]+table_fn+'\n'+html[end:]

# Map/heatmap and controls use grouped species data.
html=html.replace("const sp=state.species,vals=sp==='__all__'?D.country_iso3_counts:(D.country_iso3_species_counts?.[sp]||{})", "const sp=state.species,vals=sp==='__all__'?D.country_iso3_counts:(D.country_iso3_species_group_counts?.[sp]||{})",1)
html=html.replace("const species=sp==='__all__'?Object.keys(D.species_counts):[sp]", "const species=sp==='__all__'?(D.species_group_display_order||Object.keys(D.species_group_counts)):[sp]",1)
html=html.replace("counts=D.species_topic_level_counts?.[lev]||{}", "counts=D.species_group_topic_level_counts?.[lev]||{}",1)
html=html.replace("Object.keys(D.species_counts).forEach(s=>{mapSpecies.add(new Option(s,s));heatSpecies.add(new Option(s,s));tableSpecies.add(new Option(s,s))})", "(D.species_group_display_order||Object.keys(D.species_group_counts)).forEach(s=>{const label=s==='Unspecified salmon'?'Unspecified salmon':s;mapSpecies.add(new Option(label,s));heatSpecies.add(new Option(label,s));tableSpecies.add(new Option(label,s))})",1)

# Topic descriptions: exact hierarchy-path definitions are shown on database topic pills;
# tree nodes also expose matching definitions in their tooltip/description.
old_tree="const label=document.createElement('span');label.className='tree-name';label.textContent=name;"
new_tree="const label=document.createElement('span');label.className='tree-name';label.textContent=name;const desc=document.createElement('span');desc.className='tree-description';const defs=Object.entries(D.topic_definitions||{}).filter(([p])=>p===name||p.endsWith(' > '+name)).map(([,v])=>v).filter(Boolean);desc.textContent=defs[0]||'';if(desc.textContent)desc.title=desc.textContent;"
if old_tree in html: html=html.replace(old_tree,new_tree,1)
if 'row.append(toggle,label,count,jumpBtn);' in html: html=html.replace('row.append(toggle,label,count,jumpBtn);','row.append(toggle,label,count,jumpBtn);if(desc.textContent)row.append(desc);',1)
css_marker='.table td{padding:9px;border-top:1px solid #e8eeee;vertical-align:top}'
css_add='.project-description{max-width:1050px;margin:14px 0 0;color:#dce7e7;line-height:1.55}.country-label{cursor:help;border-bottom:1px dotted currentColor}.topic-pill{white-space:normal;line-height:1.35}.tree-description{color:var(--mid);font-size:12px;max-width:700px}.citation-doi{word-break:break-all}'
if css_marker in html and '.project-description' not in html: html=html.replace(css_marker,css_marker+css_add,1)
P.write_text(html,encoding='utf-8'); print('Applied dashboard feedback HTML patch')
