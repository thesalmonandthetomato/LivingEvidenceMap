#!/usr/bin/env python3
"""Build a deterministic human-review notification package.

Produces:
- review_manifest.json
- email_body.txt
- one Markdown prompt file per pending review case
- index.html with one case per section, copy-prompt controls, and an Open ChatGPT link

No unsupported ChatGPT prefill URL is used.
"""
import argparse, html, json
from pathlib import Path

CHATGPT_URL = "https://chatgpt.com/"


def case_prompt(case):
    return f"""I need to adjudicate one duplicate-review case for the LivingEvidenceMap pipeline.

Review case ID: {case.get('review_case_id')}
Incoming record ID: {case.get('incoming_record_id')}
Matched master record ID: {case.get('matched_master_record_id')}

Incoming title: {case.get('incoming_title')}
Matched title: {case.get('matched_master_title')}
Incoming year: {case.get('incoming_year')}
Matched year: {case.get('matched_master_year')}
Incoming first author: {case.get('incoming_first_author')}
Matched first author: {case.get('matched_master_first_author')}
Incoming DOI: {case.get('incoming_doi')}
Matched DOI: {case.get('matched_master_doi')}
Deterministic duplicate basis: {case.get('duplicate_basis')}
Title similarity: {case.get('title_similarity')}

Model decision: {case.get('model_decision')}
Model confidence: {case.get('model_confidence')}
Model rationale: {case.get('model_rationale')}
Escalation reason: {case.get('promotion_reason')}
Technical error: {case.get('technical_error')}

Please decide exactly one of: duplicate, not_duplicate, uncertain.
Explain briefly which bibliographic evidence determines the decision. DOI may be wrong and must not be decisive by itself. Do not use topical similarity alone as evidence of duplication.
""".strip()


def run(inp, outdir):
    outdir = Path(outdir)
    outdir.mkdir(parents=True, exist_ok=True)
    rows = [json.loads(x) for x in Path(inp).read_text(encoding='utf-8').splitlines() if x.strip()]
    pending = [r for r in rows if r.get('status') == 'pending']
    pending.sort(key=lambda r: r.get('review_case_id') or '')

    manifest = {
        'pending_count': len(pending),
        'chatgpt_url': CHATGPT_URL,
        'cases': []
    }

    case_sections = []
    for i, case in enumerate(pending, start=1):
        case_id = case['review_case_id']
        prompt = case_prompt(case)
        prompt_file = f"case_{i:03d}_{case_id}.md"
        (outdir / prompt_file).write_text(prompt + '\n', encoding='utf-8')
        manifest['cases'].append({
            'ordinal': i,
            'review_case_id': case_id,
            'prompt_file': prompt_file,
            'status': 'pending'
        })
        escaped_prompt = html.escape(prompt)
        case_sections.append(f"""
<section>
  <h2>Case {i}: {html.escape(case_id)}</h2>
  <pre id=\"prompt-{i}\">{escaped_prompt}</pre>
  <button onclick=\"navigator.clipboard.writeText(document.getElementById('prompt-{i}').innerText)\">Copy case prompt</button>
  <a href=\"{CHATGPT_URL}\" target=\"_blank\" rel=\"noopener noreferrer\">Open ChatGPT</a>
</section>
""")

    (outdir / 'review_manifest.json').write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')
    email_body = (
        f"LivingEvidenceMap human review required\n\n"
        f"Pending cases: {len(pending)}\n\n"
        "Open the retained review package artefact, copy the first case prompt, and open ChatGPT. "
        "Resolve cases one-by-one using the stable review_case_id shown in each prompt.\n\n"
        f"ChatGPT: {CHATGPT_URL}\n"
    )
    (outdir / 'email_body.txt').write_text(email_body, encoding='utf-8')

    html_doc = f"""<!doctype html>
<html><head><meta charset=\"utf-8\"><title>LivingEvidenceMap human review</title>
<style>body{{font-family:system-ui;max-width:1000px;margin:2rem auto;padding:0 1rem}}pre{{white-space:pre-wrap;background:#f5f5f5;padding:1rem}}section{{margin:2rem 0;padding-bottom:2rem;border-bottom:1px solid #ccc}}button,a{{margin-right:1rem}}</style>
</head><body>
<h1>LivingEvidenceMap human review</h1>
<p>{len(pending)} pending case(s). Review one case at a time.</p>
{''.join(case_sections)}
</body></html>
"""
    (outdir / 'index.html').write_text(html_doc, encoding='utf-8')


if __name__ == '__main__':
    p = argparse.ArgumentParser()
    p.add_argument('--input', required=True)
    p.add_argument('--outdir', required=True)
    a = p.parse_args()
    run(a.input, a.outdir)
