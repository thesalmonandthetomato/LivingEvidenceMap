from pathlib import Path
p=Path('docs/index.html')
s=p.read_text(encoding='utf-8')
s=s.replace('<title>Living Evidence Map — Salmon Farming</title>','<title>Research evidence on salmon farming, at a glance</title>')
s=s.replace('<h1>Salmon farming evidence, at a glance.</h1><p>Interactive view of the living master corpus. Updated automatically after validated weekly ingestion.</p>','<h1>Research evidence on salmon farming, at a glance</h1><p>An interactive view of the living evidence map. The map is updated automatically, with human oversight on a weekly basis. Data are sourced from <a href="https://www.lens.org" target="_blank" rel="noopener">www.lens.org</a>.</p>')
p.write_text(s,encoding='utf-8')
print('Updated dashboard title and subtitle.')
