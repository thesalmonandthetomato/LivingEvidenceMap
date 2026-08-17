(function () {
  'use strict';

  function init() {
    const host = document.getElementById('topicRadial');
    if (!host || typeof d3 === 'undefined' || !window.D || !Array.isArray(D.records)) return false;

    host.innerHTML = '';

    const records = D.records;
    const root = { name: 'All topics', key: '', level: -1, articleIds: new Set(), children: new Map() };

    function child(parent, name, level) {
      if (!parent.children.has(name)) {
        parent.children.set(name, {
          name,
          key: parent.key ? parent.key + ' > ' + name : name,
          level,
          articleIds: new Set(),
          children: new Map()
        });
      }
      return parent.children.get(name);
    }

    records.forEach((r, idx) => {
      const id = String(r.record_id ?? idx);
      root.articleIds.add(id);
      const paths = Array.isArray(r.topic_paths) ? r.topic_paths : [];
      const seen = new Set();
      paths.forEach(path => {
        const parts = Array.isArray(path)
          ? path.map(x => String(x).trim()).filter(Boolean)
          : String(path || '').split(/\s*>\s*/).map(x => x.trim()).filter(Boolean);
        if (!parts.length) return;
        let node = root;
        parts.slice(0, 3).forEach((name, level) => {
          node = child(node, name, level);
          if (!seen.has(node.key)) {
            node.articleIds.add(id);
            seen.add(node.key);
          }
        });
      });
    });

    function toHierarchy(node) {
      return {
        name: node.name,
        key: node.key,
        level: node.level,
        count: node.articleIds.size,
        children: Array.from(node.children.values())
          .sort((a, b) => b.articleIds.size - a.articleIds.size || a.name.localeCompare(b.name))
          .map(toHierarchy)
      };
    }

    const data = toHierarchy(root);
    const width = 560;
    const height = 560;
    const radius = Math.min(width, height) / 2 - 22;

    const hierarchy = d3.hierarchy(data);
    hierarchy.sum(d => d.children && d.children.length ? 0 : d.count);
    d3.partition().size([2 * Math.PI, radius])(hierarchy);

    const maxCount = d3.max(hierarchy.descendants(), d => d.data.count) || 1;
    const colour = d3.scaleSequential()
      .domain([0, maxCount])
      .interpolator(d3.interpolateRgb('#eef2f2', '#2c454a'));

    const svg = d3.select(host).append('svg')
      .attr('width', width)
      .attr('height', height)
      .attr('viewBox', `0 0 ${width} ${height}`)
      .attr('role', 'img')
      .attr('aria-label', 'Interactive radial topic hierarchy showing unique article counts')
      .style('width', width + 'px')
      .style('height', height + 'px')
      .style('max-width', width + 'px')
      .style('max-height', height + 'px')
      .append('g')
      .attr('transform', `translate(${width / 2},${height / 2})`);

    const arc = d3.arc()
      .startAngle(d => d.x0)
      .endAngle(d => d.x1)
      .innerRadius(d => d.y0)
      .outerRadius(d => Math.max(d.y0 + 1, d.y1 - 1.2));

    const nodes = hierarchy.descendants().filter(d => d.depth > 0);
    const paths = svg.selectAll('path.topic-radial-arc')
      .data(nodes)
      .join('path')
      .attr('class', 'topic-radial-arc')
      .attr('d', arc)
      .attr('fill', d => colour(d.data.count))
      .attr('tabindex', 0)
      .on('mouseenter', function (event, d) {
        highlight(d);
        showTip(event, d);
      })
      .on('mousemove', function (event, d) { showTip(event, d); })
      .on('mouseleave', function () { clearHighlight(); hideTip(); })
      .on('focus', function (event, d) { highlight(d); showTip(event, d); })
      .on('blur', function () { clearHighlight(); hideTip(); })
      .on('click', function (event, d) {
        event.stopPropagation();
        selectTopic(d);
      });

    const center = svg.append('g').attr('class', 'topic-radial-center')
      .on('click', () => reset());
    center.append('circle').attr('r', radius / 3.02);
    center.append('text').attr('class', 'topic-radial-center-title').attr('y', -18).text('All topics');
    center.append('text').attr('class', 'topic-radial-center-count').attr('y', 17).text(d3.format(',')(data.count));
    center.append('text').attr('class', 'topic-radial-center-sub').attr('y', 39).text('unique articles');

    function pathLabel(d) {
      return d.ancestors().reverse().slice(1).map(x => x.data.name).join(' › ');
    }

    function highlight(d) {
      paths.classed('dim', n => !(n === d || n.ancestors().includes(d) || d.ancestors().includes(n)));
      paths.classed('focus', n => n === d);
    }

    function clearHighlight() {
      paths.classed('dim', false).classed('focus', false);
    }

    function showTip(event, d) {
      const tip = document.getElementById('tip');
      if (!tip) return;
      tip.style.display = 'block';
      tip.innerHTML = `<b>${escapeHtml(d.data.name)}</b><br>${d3.format(',')(d.data.count)} unique articles<br><span style="opacity:.8">${escapeHtml(pathLabel(d))}</span>`;
      tip.style.left = `${event.clientX + 12}px`;
      tip.style.top = `${event.clientY + 12}px`;
    }

    function hideTip() {
      const tip = document.getElementById('tip');
      if (tip) tip.style.display = 'none';
    }

    function selectTopic(d) {
      if (typeof window.setFilter === 'function') {
        window.setFilter({ topic: d.data.key });
      }
      center.select('.topic-radial-center-title').text(d.data.name);
      center.select('.topic-radial-center-count').text(d3.format(',')(d.data.count));
      center.select('.topic-radial-center-sub').text('unique articles');
      highlight(d);
    }

    function reset() {
      if (typeof window.setFilter === 'function') window.setFilter({ topic: null }, false);
      clearHighlight();
      center.select('.topic-radial-center-title').text('All topics');
      center.select('.topic-radial-center-count').text(d3.format(',')(data.count));
      center.select('.topic-radial-center-sub').text('unique articles');
    }

    const resetButton = document.getElementById('topicRadialReset');
    if (resetButton) resetButton.onclick = reset;
    return true;
  }

  function escapeHtml(value) {
    return String(value ?? '').replace(/[&<>\"']/g, c => ({
      '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
    }[c]));
  }

  let attempts = 0;
  function waitForDashboard() {
    if (init()) return;
    if (++attempts < 80) setTimeout(waitForDashboard, 250);
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', waitForDashboard);
  else waitForDashboard();
})();
