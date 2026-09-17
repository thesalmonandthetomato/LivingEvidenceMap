(function(){
'use strict';
var lockedKey=null, observer=null, scheduled=false;
function escHtml(s){return String(s==null?'':s).replace(/[&<>"']/g,function(m){return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[m];});}
function ensureLayout(){
  var radial=document.getElementById('topicRadial');
  if(!radial) return null;
  var section=radial.closest('section');
  if(section){
    var sub=section.querySelector('.sub');
    if(sub) sub.textContent='Radial hierarchy of topics. High-level branches use the full dashboard palette from dark grey-teal through pale grey and peach to salmon pink. Hover over a segment to see its definition; click to filter the database and keep that definition visible.';
  }
  var layout=radial.parentElement && radial.parentElement.classList.contains('topic-radial-layout') ? radial.parentElement : null;
  if(!layout){
    layout=document.createElement('div');
    layout.className='topic-radial-layout';
    radial.parentNode.insertBefore(layout,radial);
    layout.appendChild(radial);
  }
  var info=document.getElementById('topicRadialInfo');
  if(!info){
    info=document.createElement('aside');
    info.id='topicRadialInfo';
    info.className='topic-radial-info';
    info.setAttribute('aria-live','polite');
    layout.appendChild(info);
  }
  return info;
}
function placeholder(){
  var info=ensureLayout();
  if(info) info.innerHTML='<div class="topic-radial-placeholder">Hover over a topic to see its definition. Click a topic to keep the definition visible and filter the database.</div>';
}
function showInfo(d,filtered){
  var info=ensureLayout();
  if(!info || !d || !d.data) return;
  var key=d.data.key || d.data.name || '';
  var def=(window.D && D.topic_definitions && D.topic_definitions[key]) || 'No definition is available for this topic.';
  info.innerHTML='<h3>'+escHtml(d.data.name)+'</h3><div class="topic-radial-info-path">'+escHtml(key)+'</div><p class="topic-radial-definition">'+escHtml(def)+'</p>'+(filtered?'<div class="topic-radial-filter-status"><strong>database filtered</strong><br><a href="#database">jump to the filtered database</a></div>':'');
}
function filterWithoutJump(topic){
  state.species='__all__';state.country='__all__';state.topic=null;state.year=null;state.q='';
  state.topic=topic;state.page=1;syncControls();table();
}
function wire(){
  scheduled=false;
  var info=ensureLayout();
  var radial=document.getElementById('topicRadial');
  if(!info || !radial || !window.d3 || typeof D==='undefined' || !D) return;
  var sel=d3.select(radial).selectAll('path.topic-radial-arc');
  if(sel.empty()) return;
  sel.on('click',null)
    .on('mouseenter.radialDefinition',function(e,d){if(lockedKey===null)showInfo(d,false);})
    .on('mouseleave.radialDefinition',function(){if(lockedKey===null)placeholder();})
    .on('click.radialDefinition',function(e,d){
      e.stopPropagation();
      lockedKey=d.data.key;
      sel.classed('dim',function(n){return n!==d;}).classed('focus',function(n){return n===d;});
      showInfo(d,true);
      filterWithoutJump(d.data.key);
    });
  var reset=document.getElementById('topicRadialReset');
  if(reset) reset.onclick=function(){lockedKey=null;sel.classed('dim',false).classed('focus',false).attr('opacity',1);placeholder();};
  if(lockedKey===null && !info.textContent.trim()) placeholder();
}
function scheduleWire(){if(scheduled)return;scheduled=true;setTimeout(wire,0);}
function start(){
  var radial=document.getElementById('topicRadial');
  if(!radial){setTimeout(start,100);return;}
  ensureLayout();placeholder();wire();
  observer=new MutationObserver(scheduleWire);
  observer.observe(radial,{childList:true,subtree:true});
  setTimeout(wire,900);
}
if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',start);else start();
})();
