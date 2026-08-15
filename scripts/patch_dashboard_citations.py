#!/usr/bin/env python3
"""Patch the generated dashboard HTML to display bibliographic citation details."""
from pathlib import Path

P = Path('docs/index.html')
html = P.read_text(encoding='utf-8')

old_css = '.table td{padding:9px;border-top:1px solid #e8eeee;vertical-align:top}'
new_css = '.table td{padding:9px;border-top:1px solid #e8eeee;vertical-align:top}.citation{min-width:260px}.citation .muted{margin:2px 0}.citation a{color:var(--ink);font-weight:650}.citation-doi{word-break:break-all}'
if old_css in html and '.citation{min-width:260px}' not in html:
    html = html.replace(old_css, new_css, 1)

old_head = '<th data-sort="topics">Topics ↕</th></tr>'
new_head = '<th data-sort="topics">Topics ↕</th><th>Citation</th></tr>'
if old_head in html and '<th>Citation</th>' not in html:
    html = html.replace(old_head, new_head, 1)

old_fn = "function scholarUrl(t){return 'https://scholar.google.co.uk/scholar?hl=en&as_sdt=0%2C5&q='+String(t||'').replace(/[^\\p{L}\\p{N}\\s]/gu,'').trim().replace(/\\s+/g,'+')}function recordUrl(r){return r.doi?'https://doi.org/'+encodeURIComponent(String(r.doi).replace(/^https?:\\/\\/(doi\\.org\\/)?/i,'')):scholarUrl(r.title)}"
new_fn = "function scholarUrl(t){return 'https://scholar.google.co.uk/scholar?hl=en&as_sdt=0%2C5&q='+String(t||'').replace(/[^\\p{L}\\p{N}\\s]/gu,'').trim().replace(/\\s+/g,'+')}function recordUrl(r){if(r.doi)return 'https://doi.org/'+encodeURIComponent(String(r.doi).replace(/^https?:\\/\\/(doi\\.org\\/)?/i,''));if(r.lens_url)return r.lens_url;return scholarUrl(r.title)}function citationHtml(r){const bits=[];if(r.authors)bits.push(`<div><b>${esc(r.authors)}</b></div>`);if(r.journal||r.volume||r.pages){const pub=[r.journal,r.volume?r.volume:'',r.pages?'pp. '+r.pages:''].filter(Boolean).join(', ');bits.push(`<div class=\"muted\">${esc(pub)}</div>`)}if(r.doi)bits.push(`<div class=\"muted citation-doi\">DOI: <a href=\"${esc(recordUrl(r))}\" target=\"_blank\" rel=\"noopener\">${esc(r.doi)}</a></div>`);else if(r.lens_url)bits.push(`<div class=\"muted\"><a href=\"${esc(r.lens_url)}\" target=\"_blank\" rel=\"noopener\">Lens record</a></div>`);else bits.push(`<div class=\"muted\"><a href=\"${esc(scholarUrl(r.title))}\" target=\"_blank\" rel=\"noopener\">Google Scholar</a></div>`);return bits.join('')}"
if old_fn in html:
    html = html.replace(old_fn, new_fn, 1)

old_row = '<td>${r.topics.map(t=>`<button class="pill" data-topic="${esc(t)}">${esc(t)}</button>`).join(\'\')}</td></tr>`'
new_row = '<td>${r.topics.map(t=>`<button class="pill" data-topic="${esc(t)}">${esc(t)}</button>`).join(\'\')}</td><td class="citation">${citationHtml(r)}</td></tr>`'
if old_row in html and 'class="citation">${citationHtml(r)}' not in html:
    html = html.replace(old_row, new_row, 1)

P.write_text(html, encoding='utf-8')
print('Patched dashboard citation display')
for marker in ('<th>Citation</th>', 'function citationHtml', 'citationHtml(r)'):
    if marker not in html:
        raise SystemExit(f'Citation patch marker missing: {marker}')
