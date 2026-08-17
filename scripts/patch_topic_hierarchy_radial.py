from pathlib import Path
import re

p = Path("docs/index.html")
html = p.read_text(encoding="utf-8")

section_re = re.compile(r'<section class="section"><h2>Topic hierarchy</h2>.*?</section>', re.S)
replacement = '''<section class="section"><h2>Topic hierarchy</h2><p class="sub">Radial hierarchy of topics. Ring depth shows the hierarchy; colour intensity shows the number of unique articles. Hover for counts; click a segment to filter the database.</p><div class="topic-radial-controls"><button id="topicRadialReset" type="button">Reset view</button><span class="muted">Click the centre to reset.</span></div><div id="topicRadial" class="topic-radial"></div></section>'''
html, n = section_re.subn(replacement, html, count=1)
if n != 1:
    raise SystemExit(f"Expected exactly one Topic hierarchy section, found {n}")

css = '''.topic-radial-controls{display:flex;gap:10px;align-items:center;flex-wrap:wrap;margin-bottom:10px}.topic-radial{min-height:640px;display:flex;align-items:center;justify-content:center;overflow:auto}.topic-radial svg{display:block;max-width:100%;height:auto}.topic-radial-arc{cursor:pointer;stroke:#fff;stroke-width:1.1px}.topic-radial-arc:hover{stroke:#2c454a;stroke-width:1.8px}.topic-radial-arc.dim{opacity:.16}.topic-radial-arc.focus{stroke:#2c454a;stroke-width:2px}.topic-radial-center{cursor:pointer}.topic-radial-center circle{fill:#fff;stroke:#d9e2e1}.topic-radial-center-title{font-size:14px;font-weight:700;text-anchor:middle}.topic-radial-center-count{font-size:27px;font-weight:750;text-anchor:middle}.topic-radial-center-sub{font-size:11px;fill:#577c84;text-anchor:middle}.topic-radial-note{font-size:11px;fill:#577c84;text-anchor:middle}'''
if '</style>' not in html:
    raise SystemExit('Could not find dashboard style closing tag')
html = html.replace('</style>', css + '</style>', 1)

js = r'''function tree(){
  const el=d3.select('#topicRadial');
  if(el.empty()) return;
  el.selectAll('*').remove();
  const records=Array.isArray(D.records)?D.records:[];
  const root={name:'All topics',key:'__root__',level:-1,ids:new Set(),children:new Map()};
  const nodes=new Map([['__root__',root]]);
  function nodeFor(parentKey,name,level){
    const key=parentKey+'|'+name;
    let n=nodes.get(key);
    if(!n){n={name,key,level,ids:new Set(),children:new Map(),parent:parentKey};nodes.set(key,n);nodes.get(parentKey).children.set(key,n)}
    return n;
  }
  records.forEach((r,i)=>{
    const id=String(r.record_id??r.id??r.lens_id??r.doi??r.title??i);
    root.ids.add(id);
    const paths=Array.isArray(r.topic_paths)?r.topic_paths:[];
    paths.forEach(path=>{
      const parts=Array.isArray(path)?path.map(x=>String(x).trim()).filter(Boolean):String(path||'').split(/\s*>\s*/).map(x=>x.trim()).filter(Boolean);
      if(!parts.length) return;
      let parent='__root__';
      parts.slice(0,3).forEach((name,level)=>{const n=nodeFor(parent,name,level);n.ids.add(id);parent=n.key});
    });
  });
  function toHierarchy(n){return {name:n.name,key:n.key,level:n.level,count:n.ids.size,children:[...n.children.values()].sort((a,b)=>b.ids.size-a.ids.size).map(toHierarchy)}}
  const data=toHierarchy(root),W=760,H=760,R=Math.min(W,H)/2-28;
  const svg=el.append('svg').attr('viewBox',`0 0 ${W} ${H}`).attr('aria-label','Interactive radial topic hierarchy');
  const g=svg.append('g').attr('transform',`translate(${W/2},${H/2})`);
  const h=d3.hierarchy(data).sort((a,b)=>b.data.count-a.data.count);
  d3.partition().size([2*Math.PI,R])(h);
  const maxCount=d3.max(h.descendants().filter(d=>d.depth>0),d=>d.data.count)||1;
  const color=d3.scaleSequential(d3.interpolateRgbBasis(['#eef2f1','#a8bdbe','#577c84','#2c454a'])).domain([0,maxCount]);
  const arc=d3.arc().startAngle(d=>d.x0).endAngle(d=>d.x1).innerRadius(d=>d.y0).outerRadius(d=>Math.max(d.y0+2,d.y1-1.2));
  const paths=g.selectAll('path.topic-radial-arc').data(h.descendants().filter(d=>d.depth>0)).join('path').attr('class','topic-radial-arc').attr('d',arc).attr('fill',d=>color(d.data.count));
  const center=g.append('g').attr('class','topic-radial-center').on('click',()=>reset());
  center.append('circle').attr('r',R/3.03);
  const ct=center.append('text').attr('class','topic-radial-center-title').attr('y',-19).text('All topics');
  const cc=center.append('text').attr('class','topic-radial-center-count').attr('y',15).text(fmt(root.ids.size));
  center.append('text').attr('class','topic-radial-center-sub').attr('y',37).text('unique articles');
  center.append('text').attr('class','topic-radial-note').attr('y',55).text('click to reset');
  function pathLabel(d){return d.ancestors().reverse().slice(1).map(x=>x.data.name).join(' › ')}
  function highlight(d){paths.classed('dim',n=>!(n===d||n.ancestors().includes(d)||d.ancestors().includes(n))).classed('focus',n=>n===d)}
  function clear(){paths.classed('dim',false).classed('focus',false)}
  function selectNode(d){if(d.depth>0)setFilter({topic:pathLabel(d)})}
  function zoom(d){
    const start=d.x0,end=d.x1,span=Math.max(1e-6,end-start),scale=2*Math.PI/span;
    paths.interrupt().transition().duration(450).attrTween('d',function(n){const target={x0:Math.max(0,Math.min(2*Math.PI,(n.x0-start)*scale)),x1:Math.max(0,Math.min(2*Math.PI,(n.x1-start)*scale)),y0:Math.max(0,n.y0-d.y0),y1:Math.max(0,n.y1-d.y0)},source={x0:n.x0,x1:n.x1,y0:n.y0,y1:n.y1},it=d3.interpolate(source,target);return t=>arc(it(t))});
    ct.text(d.data.name);cc.text(fmt(d.data.count));
  }
  function reset(){paths.interrupt().transition().duration(450).attr('d',arc);clear();ct.text('All topics');cc.text(fmt(root.ids.size))}
  paths.on('mouseenter',(e,d)=>{highlight(d);showTip(e,`<b>${esc(d.data.name)}</b><br>${esc(pathLabel(d))}<br>${fmt(d.data.count)} unique articles`)}).on('mouseleave',()=>{clear();hideTip()}).on('click',(e,d)=>{e.stopPropagation();selectNode(d);zoom(d)});
  document.getElementById('topicRadialReset')?.addEventListener('click',reset);
}
'''
pos=html.rfind('</script>')
if pos<0:
    raise SystemExit('Could not find dashboard script closing tag')
html=html[:pos]+js+'\n'+html[pos:]
p.write_text(html,encoding='utf-8')
print('Integrated radial topic hierarchy; database files untouched.')
