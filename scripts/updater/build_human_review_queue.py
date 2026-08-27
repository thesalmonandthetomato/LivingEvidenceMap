#!/usr/bin/env python3
"""Build a stable, lossless human-review queue from Workflow 03 results."""
import argparse, hashlib, json
from datetime import datetime, timezone
from pathlib import Path


def now():
    return datetime.now(timezone.utc).isoformat()


def stable_case_id(row):
    explicit = row.get('review_case_id')
    if explicit:
        return explicit
    seed = '|'.join(str(row.get(k) or '') for k in (
        'candidate_id', 'incoming_record_id', 'matched_master_record_id', 'promotion_reason'
    ))
    digest = hashlib.sha256(seed.encode('utf-8')).hexdigest()[:20]
    return f"hr-{digest}"


def run(inp, out):
    rows = [json.loads(x) for x in Path(inp).read_text(encoding='utf-8').splitlines() if x.strip()]
    with Path(out).open('w', encoding='utf-8', newline='\n') as f:
        for row in rows:
            if row.get('promotion') != 'human_review':
                continue
            review = {
                'workflow': '03_adjudication',
                'review_case_id': stable_case_id(row),
                'status': 'pending',
                'created_at': now(),
                'candidate_id': row.get('candidate_id'),
                'incoming_record_id': row.get('incoming_record_id'),
                'matched_master_record_id': row.get('matched_master_record_id'),
                'duplicate_basis': row.get('duplicate_basis'),
                'title_similarity': row.get('title_similarity'),
                'incoming_title': row.get('incoming_title'),
                'matched_master_title': row.get('matched_master_title'),
                'incoming_year': row.get('incoming_year'),
                'matched_master_year': row.get('matched_master_year'),
                'incoming_first_author': row.get('incoming_first_author'),
                'matched_master_first_author': row.get('matched_master_first_author'),
                'incoming_doi': row.get('incoming_doi'),
                'matched_master_doi': row.get('matched_master_doi'),
                'model_decision': row.get('decision'),
                'model_confidence': row.get('confidence'),
                'model_rationale': row.get('rationale'),
                'promotion_reason': row.get('promotion_reason'),
                'technical_error': row.get('technical_error') or row.get('adjudication_error'),
                'human_decision': None,
                'human_rationale': None,
                'resolved_at': None,
            }
            f.write(json.dumps(review, ensure_ascii=False, separators=(',', ':')) + '\n')


if __name__ == '__main__':
    p = argparse.ArgumentParser()
    p.add_argument('--input', required=True)
    p.add_argument('--output', required=True)
    a = p.parse_args()
    run(a.input, a.output)
