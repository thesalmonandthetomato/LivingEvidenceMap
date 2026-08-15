#!/usr/bin/env python3
from pathlib import Path
p = Path('scripts/build_dashboard_html_v2.py')
s = p.read_text(encoding='utf-8')
bad = "scrollIntoView({behavior:'smooth',block:'start')}function setFilter"
good = "scrollIntoView({behavior:'smooth',block:'start'});}function setFilter"
if bad not in s:
    if "scrollIntoView({behavior:'smooth',block:'start'});}" in s:
        print('Dashboard builder already repaired.')
    else:
        raise SystemExit('Expected broken jump() signature not found; refusing to modify builder')
else:
    p.write_text(s.replace(bad, good, 1), encoding='utf-8')
    print('Repaired dashboard builder jump() syntax.')
