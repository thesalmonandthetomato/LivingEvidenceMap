from pathlib import Path

p = Path('docs/index.html')
html = p.read_text(encoding='utf-8')
marker = '<!-- cluster-database-topic-dropdown -->'
if marker in html:
    print('Topic dropdown clustering already applied')
    raise SystemExit

js = r'''<!-- cluster-database-topic-dropdown -->
<script>
(function(){
  function clusterTopics(){
    const sel=document.getElementById('tableTopic');
    if(!sel || sel.dataset.clustered==='1') return;
    const opts=[...sel.options].filter(o=>o.value!=='__all__');
    if(!opts.length) return;
    const groups=new Map();
    opts.forEach(o=>{
      const label=o.textContent.trim();
      const top=(label.split(' > ')[0]||'Unspecified topic').trim();
      if(!groups.has(top)) groups.set(top,[]);
      groups.get(top).push(o);
    });
    while(sel.options.length>1) sel.remove(1);
    [...groups.keys()].sort((a,b)=>a.localeCompare(b)).forEach(top=>{
      const og=document.createElement('optgroup');
      og.label=top;
      groups.get(top).sort((a,b)=>a.textContent.localeCompare(b.textContent)).forEach(o=>og.appendChild(o));
      sel.appendChild(og);
    });
    sel.dataset.clustered='1';
  }
  const oldInit=window.init;
  clusterTopics();
  const obs=new MutationObserver(clusterTopics);
  const sel=document.getElementById('tableTopic');
  if(sel) obs.observe(sel,{childList:true,subtree:true});
  setTimeout(clusterTopics,100);
  setTimeout(clusterTopics,500);
  setTimeout(clusterTopics,1500);
})();
</script>
'''
html = html.replace('</body>', js + '</body>')
p.write_text(html, encoding='utf-8')
print('Clustered database topic dropdown by top-level hierarchy')