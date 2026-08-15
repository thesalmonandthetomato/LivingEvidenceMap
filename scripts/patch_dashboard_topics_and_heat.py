from pathlib import Path

p = Path('docs/index.html')
html = p.read_text(encoding='utf-8')

# Topic display: use adjacent hierarchy levels rather than the mixed flat topic list.
# The first level is represented by a colour class; paths are deduplicated and capped
# to keep the database readable when a record has many assignments.
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
  if(!pairs.length) return r.topics.map(t=>`<span class="topic-chip topic-l1">${esc(t)}</span>`).join('');
  return pairs.map(p=>`<span class="topic-chip topic-l${Math.min(p.level,4)}"><span class="topic-root">${esc(p.root)}</span> <span class="topic-sep">›</span> ${esc(p.b)}${p.a!==p.root?`<span class="topic-parent"> (${esc(p.a)})</span>`:''}</span>`).join('');
}'''
if needle not in html:
    raise SystemExit('Could not find scholarUrl insertion point')
html = html.replace(needle, insert, 1)

old_topics = "${r.topics.map(t=>`<button class=\"pill\" data-topic=\"${esc(t)}\">${esc(t)}</button>`).join('')}"
if old_topics not in html:
    raise SystemExit('Could not find database topic rendering')
html = html.replace(old_topics, "${topicHtml(r)}", 1)

# Heatmap: zero is a neutral light grey; only positive values enter the colour scale.
old_heat = ".attr('fill',color(counts[`${s}|||${t}`]||0))"
if old_heat not in html:
    raise SystemExit('Could not find heatmap fill expression')
html = html.replace(old_heat, ".attr('fill',((counts[`${s}|||${t}`]||0)===0)?'#f0f2f1':color(counts[`${s}|||${t}`]||0))", 1)
old_domain = ".domain([0,max])"
if old_domain not in html:
    raise SystemExit('Could not find heatmap colour domain')
# There are two sequential colour domains; the second occurrence is the heatmap.
pos = html.find(old_domain)
pos2 = html.find(old_domain, pos + 1)
if pos2 < 0:
    raise SystemExit('Could not find heatmap colour domain occurrence')
html = html[:pos2] + html[pos2:].replace(old_domain, ".domain([1,max])", 1)

css_needle = ".pill{display:inline-block;background:#eaf0ef;border-radius:99px;padding:3px 7px;margin:2px;font-size:11px;border:0}.muted"
css_insert = ".pill{display:inline-block;background:#eaf0ef;border-radius:99px;padding:3px 7px;margin:2px;font-size:11px;border:0}.topic-chip{display:inline-block;border-radius:7px;padding:4px 7px;margin:2px 3px 2px 0;font-size:11px;line-height:1.25;border-left:4px solid var(--mid);background:#eef3f2}.topic-l1{border-left-color:#2c454a}.topic-l2{border-left-color:#577c84}.topic-l3{border-left-color:#a8bdbe}.topic-l4{border-left-color:#e2b8a2}.topic-root{font-weight:700}.topic-sep{color:var(--mid);padding:0 2px}.topic-parent{color:var(--mid);font-style:italic}.muted"
if css_needle not in html:
    raise SystemExit('Could not find CSS insertion point')
html = html.replace(css_needle, css_insert, 1)

p.write_text(html, encoding='utf-8')
print('Patched topic display and zero heatmap colour')
