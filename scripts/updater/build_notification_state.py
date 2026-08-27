#!/usr/bin/env python3
"""Build deterministic notification state for a pending human-review queue.

The fingerprint is stable for the same ordered set of pending review_case_id values.
This allows notification transport to suppress duplicate emails on workflow reruns.
"""
import argparse, hashlib, json
from pathlib import Path


def run(inp, out):
    rows=[json.loads(x) for x in Path(inp).read_text(encoding='utf-8').splitlines() if x.strip()]
    pending=sorted(r['review_case_id'] for r in rows if r.get('status')=='pending')
    canonical='\n'.join(pending).encode('utf-8')
    fingerprint=hashlib.sha256(canonical).hexdigest()
    state={
        'pending_count': len(pending),
        'pending_review_case_ids': pending,
        'notification_fingerprint': fingerprint,
        'should_notify': bool(pending),
    }
    Path(out).parent.mkdir(parents=True,exist_ok=True)
    Path(out).write_text(json.dumps(state,indent=2,ensure_ascii=False)+'\n',encoding='utf-8')

if __name__=='__main__':
    p=argparse.ArgumentParser(); p.add_argument('--input',required=True); p.add_argument('--output',required=True); a=p.parse_args()
    run(a.input,a.output)
