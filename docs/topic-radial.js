(function () {
  'use strict';

  function init() {
    const host = document.getElementById('topicRadial');
    if (!host || typeof d3 === 'undefined' || typeof D === 'undefined' || !Array.isArray(D.records)) return false;

    host.innerHTML = '';
    host.style.setProperty('width', '576px', 'important');
    host.style.setProperty('height', '576px', 'important');
    host.style.setProperty('min-height', '576px', 'important');
    host.style.setProperty('max-width', '576px', 'important');
    host.style.setProperty('max-height', '576px', 'important');
    host.style.setProperty('overflow', 'hidden', 'important');
    host.style.setProperty('flex', '0 0 576px', 'important');

    const records = D.records;
    const root = { name: 'All topics', key: '', level: -1, articleIds: new Set(), children: new Map() };

    function child(parent, name, level) {
      if (!parent.children.has(name)) parent.children.set(name, { name, key: parent.key ? parent.key + ' > ' + name : name, level, articleIds: new Set(), children: new Map() });
      return parent.children.get(name);
    }

    records.forEach((r, idx) => {
      const id = String(r.record_id ?? idx);
      root.articleIds.add(id);
      const paths = Array.isArray(r.topic_paths) ? r.topic_paths : [];
      const seen = new Set();
      paths.forEach(path => {
        const parts = Array.isArray(path) ? path.map(x => String(x).trim()).filter(Boolean) : String(path || '').split(/\s*>\s*/).map(x => x.trim()).filter(Boolean);
        if (!parts.length) return;
        let node = root;
        parts.slice(0, 3).forEach((name, level) => {
          node = child(node, name, level);
          if (!seen.has(node.key)) { node.articleIds.add(id); seen.add(node.key); }
        });
      });
    });

    function toHierarchy(node) {
      return { name: node.name, key: node.key, level: node.level, count: node.articleIds.size, children: Array.from(node.children.values()).sort((a,b) => b.articleIds.size - a.articleIds.size || a.name.localeCompare(b.name)).map(toHierarchy) };
    }

    const data = toHierarchy(root);
    const width = 576;
    const height = 576;
    const radius = Math.min(width, height) / 2 - 18;
    const hierarchy = d3.hierarchy(data);
    hierarchy.sum(d => d.children && d.children.length ? 0 : d.count);
    d3.partition().size([2 * Math.PI, radius])(hierarchy);

    const maxCount = d3.max(hierarchy.descendants(), d => d.data.count) || 1;
    const colour = d3.scaleSequential().domain([0, maxCount]).interpolator(d3.interpolateRgb('#eef2f2', '#2c454a'));

    const svg = d3.select(host).append('svg').attr('width', width).attr('height', height).attr('viewBox', `0 0 ${width} ${height}`).attr('role', 'img').attr('aria-label', 'Interactive radial topic hierarchy showing unique article counts').append('g').attr('transform', `translate(${width / 2},${height / 2})`);

    const svgNode = host.querySelector('svg');
    if (svgNode) {
      svgNode.style.setProperty('width', width + 'px', 'important');
      svgNode.style.setProperty('height', height + 'px', 'important');
      svgNode.style.setProperty('max-width', width + 'px', 'important');
      svgNode.style.setProperty('max-height', height + 'px', 'important');
      svgNode.style.setProperty('display', 'block', 'important');
      svgNode.style.setProperty('flex', '0 0 ' + width + 'px', 'important');
    }

    const arc = d3.arc().startAngle(d => d.x0).endAngle(d => d.x1).innerRadius(d => d.y0).outerRadius(d => Math.max(d.y0 + 1, d.y1 - 1.2));
    const nodes = hierarchy.descendants().filter(d => d.depth > 0);
    const paths = svg.selectAll('path.topic-radial-arc').data(nodes).join('path').attr('class', 'topic-radial-arc').attr('d', arc).attr('fill', d => colour(d.data.count)).attr('tabindex', 0)
      .on('mouseenter', function(event, d) { highlight(d); showTip(event, d); })
      .on('mousemove', function(event, d) { showTip(event, d); })
      .on('mouseleave', function() { clearHighlight(); hideTip(); })
      .on('focus', function(event, d) { highlight(d); showTip(event, d); })
      .on('blur', function() { clearHighlight(); hideTip(); });

    const center = svg.append('g').attr('class', 'topic-radial-center');
    center.append('circle').attr('r', radius / 3.02);
    center.append('text').attr('class', 'topic-radial-center-title').attr('y', -18).text('All topics');
    center.append('text').attr('class', 'topic-radial-center-count').attr('y', 17).text(d3.format(',')(data.count));
    center.append('text').attr('class', 'topic-radial-center-sub').attr('y', 39).text('unique articles');

    function pathLabel(d) { return d.ancestors().reverse().slice(1).map(x => x.data.name).join(' › '); }
    function highlight(d) { paths.classed('dim', n => !(n === d || n.ancestors().includes(d) || d.ancestors().includes(n))); paths.classed('focus', n => n === d); }
    function clearHighlight() { paths.classed('dim', false).classed('focus', false); }
    function showTip(event, d) {
      const tip = document.getElementById('tip');
      if (!tip) return;
      tip.style.display = 'block';
      tip.innerHTML = `<b>${escapeHtml(d.data.name)}</b><br>${d3.format(',')(d.data.count)} unique articles<br><span style="opacity:.8">${escapeHtml(pathLabel(d))}</span>`;
      tip.style.left = `${event.clientX + 12}px`;
      tip.style.top = `${event.clientY + 12}px`;
    }
    function hideTip() { const tip = document.getElementById('tip'); if (tip) tip.style.display = 'none'; }
    const resetButton = document.getElementById('topicRadialReset');
    if (resetButton) resetButton.onclick = clearHighlight;

    // The main dashboard declares D with `let`, so it is not on window.D.
    // The hierarchical heatmap initialiser expects window.D; expose the same
    // in-memory object here and initialise the heatmap once D is available.
    window.D = D;
    if (typeof window.configureHeat === 'function') window.configureHeat();

    // The species values already exist in D.records. This presentation-only
    // patch adds that existing field to the database table; it does not modify
    // D, dashboard.json, the master CSV, or any filters/data.
    installSpeciesColumn();
    return true;
  }

  function installSpeciesColumn() {
    const styleId = 'species-column-style';
    if (!document.getElementById(styleId)) {
      const style = document.createElement('style');
      style.id = styleId;
      style.textContent = '.database-species-cell{white-space:normal;min-width:150px}.database-species-cell .pill{margin:2px 2px 2px 0}';
      document.head.appendChild(style);
    }

    const normalise = value => String(value ?? '').replace(/\s+/g, ' ').trim().toLowerCase();
    const findRecord = row => {
      const cells = row.querySelectorAll('td');
      if (!cells.length) return null;
      const first = normalise(cells[0].textContent);
      if (!first) return null;
      return D.records.find(r => {
        const title = normalise(r.title);
        return title && (first.startsWith(title) || first.includes(title));
      }) || null;
    };

    const apply = () => {
      const table = document.querySelector('#database table.table');
      const theadRow = table && table.querySelector('thead tr');
      const tbody = table && table.querySelector('tbody');
      if (!theadRow || !tbody) return;

      if (!theadRow.querySelector('th[data-species-column="true"]')) {
        const th = document.createElement('th');
        th.textContent = 'Species';
        th.setAttribute('data-species-column', 'true');
        theadRow.insertBefore(th, theadRow.children[1] || null);
      }

      tbody.querySelectorAll('tr').forEach(row => {
        if (row.querySelector('td[data-species-column="true"]')) return;
        const record = findRecord(row);
        const td = document.createElement('td');
        td.className = 'database-species-cell';
        td.setAttribute('data-species-column', 'true');
        const species = record && Array.isArray(record.species) ? record.species : (record && record.species ? [record.species] : []);
        td.innerHTML = species.map(s => `<span class="pill">${escapeHtml(s)}</span>`).join('');
        row.insertBefore(td, row.children[1] || null);
      });
    };

    apply();
    const observer = new MutationObserver(apply);
    const target = document.getElementById('database');
    if (target) observer.observe(target, { childList: true, subtree: true });
  }

  function escapeHtml(value) { return String(value ?? '').replace(/[&<>\"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c])); }
  let attempts = 0;
  function waitForDashboard() { if (init()) return; if (++attempts < 80) setTimeout(waitForDashboard, 250); }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', waitForDashboard); else waitForDashboard();
})();