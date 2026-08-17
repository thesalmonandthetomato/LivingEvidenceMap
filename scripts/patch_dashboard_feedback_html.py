#!/usr/bin/env python3
"""Final dashboard presentation patch."""
from pathlib import Path
import re
P=Path('docs/index.html'); html=P.read_text(encoding='utf-8')
# Keep all existing approved database rendering/filtering. Only reorganise topic dropdown options below.
# Replace the topic-option population with optgroups based on the FIRST hierarchy level.
needle="Object.keys(D.topic_counts||{}).sort().forEach(t=>tableTopic.add(new Option(t,t)));"
replacement="""const topicGroups={}; Object.keys(D.topic_counts||{}).sort((a,b)=>a.localeCompare(b)).forEach(t=>{const top=String(t).split(' > ')[0]||'Other';(topicGroups[top]??=[]).push(t)});Object.keys(topicGroups).sort((a,b)=>a.localeCompare(b)).forEach(top=>{const group=document.createElement('optgroup');group.label=top;topicGroups[top].forEach(t=>group.appendChild(new Option(t,t)));tableTopic.appendChild(group)});"""
if needle in html: html=html.replace(needle,replacement,1)
else:
    # Handle equivalent population code if the generated HTML uses a slightly different form.
    pat=r"Object\.keys\(D\.topic_counts\|\|\{\}\)\.sort\(\)\.forEach\(t=>tableTopic\.add\(new Option\(t,t\)\)\);"
    html,n=re.subn(pat,replacement,html,count=1)
    if n==0: print('WARNING: topic dropdown population pattern not found')
P.write_text(html,encoding='utf-8')
print('Database topic dropdown clustered by top-level hierarchy only')