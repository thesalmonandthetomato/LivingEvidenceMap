#!/usr/bin/env python3
import hashlib
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

canonical_path = Path(sys.argv[1])
manifest_path = Path(sys.argv[2])
recovered_path = Path(sys.argv[3])
audit_path = Path(sys.argv[4])

manifest = json.loads(manifest_path.read_text(encoding='utf-8'))
expected_before = 21851
if manifest.get('record_count') != expected_before:
    raise RuntimeError(f"Expected manifest record_count {expected_before}, found {manifest.get('record_count')}")

canonical_ids = set()
before_count = 0
with canonical_path.open(encoding='utf-8') as fh:
    for line in fh:
        if not line.strip():
            continue
        before_count += 1
        rec = json.loads(line)
        lid = (rec.get('identity') or {}).get('lens_id')
        if not lid:
            raise RuntimeError(f'Existing canonical record {before_count} has no identity.lens_id')
        if lid in canonical_ids:
            raise RuntimeError(f'Duplicate Lens ID already in canonical corpus: {lid}')
        canonical_ids.add(lid)
if before_count != expected_before:
    raise RuntimeError(f'Expected {expected_before} canonical JSONL records, found {before_count}')

recovered = []
recovered_ids = set()
with recovered_path.open(encoding='utf-8') as fh:
    for line in fh:
        if not line.strip():
            continue
        rec = json.loads(line)
        lid = (rec.get('identity') or {}).get('lens_id')
        raw_lid = ((rec.get('lens') or {}).get('raw_payload') or {}).get('lens_id')
        if not lid or lid != raw_lid:
            raise RuntimeError(f'Recovered wrapper/raw Lens ID mismatch: {lid!r} vs {raw_lid!r}')
        if lid in recovered_ids:
            raise RuntimeError(f'Duplicate Lens ID in recovered set: {lid}')
        recovered_ids.add(lid)
        recovered.append(rec)
if len(recovered) != 280:
    raise RuntimeError(f'Expected 280 recovered records, found {len(recovered)}')

overlap = sorted(canonical_ids & recovered_ids)
if overlap:
    raise RuntimeError(f'Exact Lens-ID overlap found; refusing append: {overlap[:20]}')

def canonical_from_lens(raw):
    doi = None
    for ext in raw.get('external_ids') or []:
        if str(ext.get('type', '')).lower() == 'doi' and ext.get('value'):
            doi = ext.get('value')
            break
    source = raw.get('source')
    source_title = source.get('title') if isinstance(source, dict) else source
    return {
        'title': raw.get('title'),
        'authors': raw.get('authors') or [],
        'year': raw.get('year_published'),
        'source': source_title,
        'doi': doi,
        'abstract': raw.get('abstract'),
    }

for rec in recovered:
    raw = rec['lens']['raw_payload']
    rec['canonical'] = canonical_from_lens(raw)
    provenance = rec.setdefault('provenance', {})
    provenance['historical_screening'] = {
        'decision': 'INCLUDE',
        'source': 'INCLUDES(1).ris',
        'basis': 'historical_screening_export',
    }
    provenance['historical_include_recovery'] = {
        'workflow_run_id': 33274405524,
        'artifact_id': 9721057470,
        'deduplication_key': 'lens_id',
    }

with canonical_path.open('a', encoding='utf-8', newline='') as out:
    for rec in recovered:
        out.write(json.dumps(rec, ensure_ascii=False, separators=(',', ':')) + '\n')

final_ids = set()
after_count = 0
with canonical_path.open(encoding='utf-8') as fh:
    for line in fh:
        if not line.strip():
            continue
        after_count += 1
        rec = json.loads(line)
        lid = (rec.get('identity') or {}).get('lens_id')
        if not lid:
            raise RuntimeError(f'Final canonical record {after_count} has no identity.lens_id')
        if lid in final_ids:
            raise RuntimeError(f'Duplicate Lens ID after append: {lid}')
        final_ids.add(lid)

expected_after = expected_before + 280
if after_count != expected_after:
    raise RuntimeError(f'Expected {expected_after} records after append, found {after_count}')
if not recovered_ids.issubset(final_ids):
    raise RuntimeError('Not all recovered Lens IDs are present after append')

digest = hashlib.sha256(canonical_path.read_bytes()).hexdigest()
manifest['created_at'] = datetime.now(timezone.utc).isoformat()
manifest['record_count'] = after_count
manifest['records_sha256'] = digest
manifest['historical_lens_include_recovery'] = {
    'source_unmatched_records': 281,
    'lens_backed_records_considered': 280,
    'records_appended': 280,
    'exact_lens_id_overlaps': 0,
    'deduplication_key': 'lens_id',
    'source_workflow_run_id': 33274405524,
    'source_artifact_id': 9721057470,
    'non_lens_record_out_of_scope': 1,
}
manifest['notes'] = (manifest.get('notes') or '').rstrip() + ' Appended 280 historical INCLUDE records recovered by exact Lens ID; deduplicated solely on identity.lens_id; one non-Lens historical record left out of scope.'
manifest_path.write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')

audit = {
    'before_count': before_count,
    'recovered_count': len(recovered),
    'exact_lens_id_overlap': len(overlap),
    'appended_count': 280,
    'after_count': after_count,
    'unique_final_lens_ids': len(final_ids),
    'records_sha256': digest,
    'historical_decision_attached': 'INCLUDE',
    'canonical_fields_derived_directly_from_lens_raw_payload': True,
}
audit_path.write_text(json.dumps(audit, indent=2) + '\n', encoding='utf-8')
print(json.dumps(audit, indent=2))
