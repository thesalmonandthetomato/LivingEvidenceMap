#!/usr/bin/env python3
# Apply the completed 153-record topic recovery ONLY to existing master records.
# This is a topic repair, not a master+update merge.
import csv
from collections import defaultdict
from pathlib import Path

MASTER = Path('data/reference/salmon_evidence_map.csv')
TOPICS = Path('topic_artifact/topic_assignments.csv')
OUT = Path('data/reference/salmon_evidence_map_topic_repaired.csv')


def read_csv(path):
    with path.open(newline='', encoding='utf-8-sig') as f:
        r = csv.DictReader(f)
        return list(r), list(r.fieldnames or [])


def norm(v):
    return '' if v is None else str(v).strip()


def topic_map(path):
    rows, cols = read_csv(path)
    required = {'record_id', 'hierarchy_path', 'path_id'}
    missing = required - set(cols)
    if missing:
        raise SystemExit(f'Topic artifact missing columns: {sorted(missing)}')
    d = defaultdict(lambda: {'ids': set(), 'paths': set(), 'review': False, 'reasons': set()})
    for r in rows:
        rid = norm(r.get('record_id'))
        if not rid or norm(r.get('status')).lower() != 'completed':
            continue
        if norm(r.get('path_id')):
            d[rid]['ids'].add(norm(r['path_id']))
        if norm(r.get('hierarchy_path')):
            d[rid]['paths'].add(norm(r['hierarchy_path']))
        if norm(r.get('review_required')).lower() in {'true','1','yes'}:
            d[rid]['review'] = True
        if norm(r.get('review_reason')):
            d[rid]['reasons'].add(norm(r['review_reason']))
    return d, len(rows), len(d)


def main():
    master, cols = read_csv(MASTER)
    topics, topic_rows, topic_records = topic_map(TOPICS)
    if 'record_id' not in cols:
        raise SystemExit('Master has no record_id column')

    # Never add records. Never use the 1381-record update here.
    master_ids = {norm(r.get('record_id')) for r in master if norm(r.get('record_id'))}
    topic_ids = set(topics)
    absent = sorted(topic_ids - master_ids)
    if absent:
        raise SystemExit(f'{len(absent)} topic-recovery IDs are not present in the authoritative master; refusing to add records. First IDs: {", ".join(absent[:20])}')

    if 'topic_path_ids' not in cols:
        cols.append('topic_path_ids')
    if 'topic_hierarchy_paths' not in cols:
        cols.append('topic_hierarchy_paths')
    if 'topic_review_required' not in cols:
        cols.append('topic_review_required')
    if 'topic_review_reason' not in cols:
        cols.append('topic_review_reason')

    repaired = 0
    already_complete = 0
    missing_topic_output = []
    for r in master:
        rid = norm(r.get('record_id'))
        if rid not in topics:
            continue
        t = topics[rid]
        if not t['paths']:
            missing_topic_output.append(rid)
            continue
        existing = norm(r.get('topic_hierarchy_paths'))
        existing_ids = norm(r.get('topic_path_ids'))
        # Recovery is intended to fill gaps. Do not overwrite an existing non-empty hierarchy.
        if existing and existing_ids:
            already_complete += 1
            continue
        r['topic_path_ids'] = '; '.join(sorted(t['ids']))
        r['topic_hierarchy_paths'] = '; '.join(sorted(t['paths']))
        r['topic_review_required'] = 'TRUE' if t['review'] else 'FALSE'
        r['topic_review_reason'] = '; '.join(sorted(t['reasons']))
        repaired += 1

    if missing_topic_output:
        raise SystemExit(f'{len(missing_topic_output)} topic-recovery records have no completed hierarchy output: {", ".join(missing_topic_output[:20])}')

    with OUT.open('w', newline='', encoding='utf-8') as f:
        w = csv.DictWriter(f, fieldnames=cols, extrasaction='ignore')
        w.writeheader()
        for r in master:
            w.writerow({c: r.get(c, '') for c in cols})

    print(f'Authoritative master records: {len(master)}')
    print(f'Topic artifact rows: {topic_rows}')
    print(f'Topic records: {topic_records}')
    print(f'Topic IDs absent from master: 0')
    print(f'Records repaired with 153-topic set: {repaired}')
    print(f'Records already complete and preserved: {already_complete}')
    print(f'Output records: {len(master)}')


if __name__ == '__main__':
    main()
