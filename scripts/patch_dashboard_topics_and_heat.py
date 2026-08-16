from pathlib import Path

p = Path('docs/index.html')
html = p.read_text(encoding='utf-8')

# Topic display: use adjacent hierarchy levels rather than the mixed flat topic list.
# The first-level ancestor controls the colour; paths are deduplicated and capped.
needle = "function scholarUrl(t){return 'https://scholar.google.co.uk/scholar?hl=en&as_sdt=0%2C5&q='+String(t||'').replace(/[^\\p{L}\\p{N}\\s]/gu,'').trim().replace(/\\s+/g,'+')}"
insert = r'''function scholarUrl(t){return 'https://scholar.google.co.uk/scholar?hl=en&as_sdt=0%2C5&q='+String(t||'').replace(/[^\p{L}\p{N}\s]/gu,'').trim().replace(/\s+/g,'+')}
function topicPairs(r){
  const paths = Array.isArray(r.topic_paths) ? r.topic_paths : [];
  const out=[];
  const seen=new Set();
  paths.forEach(path=>{
    const parts=String(path||'').split(/\s*>\s*/).map(x=>x.trim()).filter(Boolean);
    for(let i=0;i<parts.length-1;i++){
      const key=`${parts[0]}|||${parts[i]}|||${parts[i+1]}`;
      if(!seen.has(key)){
        seen.add(key);
        out.push({root:parts[0],a:parts[i],b:parts[i+1],level:i+1});
      }
    }
  });
  return out.slice(0,8);
}
function topicHtml(r){
  const pairs=topicPairs(r);
  if(!pairs.length) return (r.topics||[]).filter(t=>t!=='Species').map(t=>`<span class="topic-chip topic-l1">${esc(t)}</span>`).join('');
  return pairs.map(p=>`<span class="topic-chip topic-l${Math.min(p.level,4)}"><span class="topic-level">${esc(p.a)} <span class="topic-sep">›</span> ${esc(p.b)}</span></span>`).join('');
}'''
if needle not in html:
    raise SystemExit('Could not find scholarUrl insertion point')
html = html.replace(needle, insert, 1)

old_topics = "${r.topics.map(t=>`<button class=\"pill\" data-topic=\"${esc(t)}\">${esc(t)}</button>`).join('')}"
if old_topics in html:
    html = html.replace(old_topics, "${topicHtml(r)}", 1)

# Heatmap: zero is near-white; only positive values enter the colour scale.
old_heat = ".attr('fill',color(counts[`${s}|||${t}`]||0))"
if old_heat in html:
    html = html.replace(old_heat, ".attr('fill',((counts[`${s}|||${t}`]||0)===0)?'#f8f9f8':color(counts[`${s}|||${t}`]||0))", 1)
old_domain = ".domain([0,max])"
pos = html.find(old_domain)
pos2 = html.find(old_domain, pos + 1)
if pos2 >= 0:
    html = html[:pos2] + html[pos2:].replace(old_domain, ".domain([1,max])", 1)

# Heatmap hierarchy control: selecting a top-level branch restricts the
# available topic-level choices to the deeper layers (levels 3 and 4).
marker = "function heat(){"
if marker not in html:
    raise SystemExit('Could not find heat function')
start = html.index(marker)
end = html.index("function tree(){", start)
heat_fn = r'''function syncHeatLevels(){
  const current=heatLevel.value;
  const top=heatTop.value;
  const labels=D.topic_level_labels||{};
  const levels=Object.keys(labels).sort((a,b)=>Number(a)-Number(b));
  const allowed=top==='__all__'?levels:levels.filter(l=>Number(l)>=3);
  heatLevel.innerHTML='';
  allowed.forEach(l=>heatLevel.add(new Option(labels[l]||`Level ${l}`,l)));
  if(allowed.includes(current)) heatLevel.value=current;
  else if(allowed.length) heatLevel.value=allowed[0];
}
function heat(){const el=d3.select('#heatmap');el.selectAll('*').remove();const lev=heatLevel.value||'1',top=heatTop.value,sp=heatSpecies.value,limit=+heatLimit.value;let topics=Object.entries(D.topic_level_counts?.[lev]||{}).sort((a,b)=>b[1]-a[1]).map(x=>x[0]);if(top!=='__all__'){const allowed=new Set();function walk(obj,on){Object.entries(obj||{}).forEach(([k,n])=>{const active=on||k===top;if(active)allowed.add(k);walk(n.children,active)})}walk(D.topic_tree,false);topics=topics.filter(t=>allowed.has(t))}topics=topics.slice(0,limit);const species=sp==='__all__'?Object.keys(D.species_counts):[sp],cw=70,ch=34,left=190,bottom=250,w=Math.max(900,left+topics.length*cw+20),h=50+species.length*ch+bottom,svg=el.append('svg').attr('width',w).attr('height',h),counts=D.species_topic_level_counts?.[lev]||{},max=d3.max(species.flatMap(s=>topics.map(t=>counts[`${s}|||${t}`]||0)))||1,color=d3.scaleSequential(d3.interpolateRgbBasis([palette[2],palette[1],palette[0],palette[5]])).domain([1,max]);species.forEach((s,i)=>topics.forEach((t,j)=>svg.append('rect').attr('x',left+j*cw).attr('y',40+i*ch).attr('width',cw).attr('height',ch).attr('fill',((counts[`${s}|||${t}`]||0)===0)?'#f8f9f8':color(counts[`${s}|||${t}`]||0)).attr('class','heat-cell').on('click',()=>setFilter({species:s,topic:t})).on('mousemove',e=>showTip(e,`<b>${esc(s)}</b><br>${esc(t)}<br>${fmt(counts[`${s}|||${t}`]||0)} records`)).on('mouseleave',hideTip)));svg.selectAll('.slabel').data(species).join('text').attr('x',left-8).attr('y',(s,i)=>40+i*ch+22).attr('text-anchor','end').attr('class','axis').text(s=>s);svg.selectAll('.tlabel').data(topics).join('text').attr('transform',(t,i)=>`translate(${left+i*cw+cw/2},${40+species.length*ch+22}) rotate(-55)`).attr('text-anchor','end').attr('class','axis').text(t=>t.length>34?t.slice(0,32)+'…':t)}
'''
html = html[:start] + heat_fn + html[end:]

old_bind = "heatSpecies.onchange=heat;heatTop.onchange=heat;heatLevel.onchange=heat;heatLimit.onchange=heat;"
new_bind = "heatSpecies.onchange=heat;heatTop.onchange=()=>{syncHeatLevels();heat()};heatLevel.onchange=heat;heatLimit.onchange=heat;"
if old_bind not in html:
    raise SystemExit('Could not find heatmap event bindings')
html = html.replace(old_bind, new_bind, 1)

old_init = "Object.entries(D.topic_level_labels||{}).forEach(([k,v])=>heatLevel.add(new Option(v,k)));Object.keys(D.topic_tree||{}).forEach(t=>heatTop.add(new Option(t,t)));"
new_init = "Object.entries(D.topic_level_labels||{}).forEach(([k,v])=>heatLevel.add(new Option(v,k)));Object.keys(D.topic_tree||{}).forEach(t=>heatTop.add(new Option(t,t)));syncHeatLevels();"
if old_init not in html:
    raise SystemExit('Could not find heatmap level initialisation')
html = html.replace(old_init, new_init, 1)

p.write_text(html, encoding='utf-8')
print('Patched topic display, dependent heatmap levels, and zero heatmap colour')
