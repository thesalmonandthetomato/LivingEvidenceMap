import base64
import copy
import hashlib
import json
import os
from datetime import datetime, timezone
from pathlib import Path

records_path = Path('data/canonical/current/repair/records.jsonl')
manifest_path = Path('data/canonical/current/repair/manifest.json')
archive_dir = Path('data/canonical/archive/repair/08_historical_excludes_reconciliation')
archive_dir.mkdir(parents=True, exist_ok=True)
audit_path = archive_dir / 'screening_adjudication_audit.jsonl'
archive_manifest_path = archive_dir / 'manifest.json'

EXPECTED_RECORDS = 22148
EXPECTED_TARGETS = 5953
EXPECTED_SORTED_ID_SHA256 = 'c08d310a033037fcca7f2d7f9f0f9f8efd34c4ab10e855c367a1fce928c35080'
ADJUDICATION_DATE = '2026-08-30'

# Membership bitset over the lexicographically sorted 22,148 current Lens IDs.
# This compact representation was derived from the independently verified EXCLUDES(3).ris reconciliation.
TARGET_BITSET_B64 = '''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'''

new_relevance = {
    'decision': 'EXCLUDE',
    'decision_source': 'historical_excludes_ris',
    'adjudication_set': 'historical_EXCLUDES(3).ris_reconciliation',
    'adjudication_date': ADJUDICATION_DATE,
    'decision_basis': 'matched_to_historical_EXCLUDES(3).ris',
}

raw_lines = records_path.read_text(encoding='utf-8').splitlines()
assert len(raw_lines) == EXPECTED_RECORDS, f'Expected {EXPECTED_RECORDS} records, found {len(raw_lines)}'

records = []
ids = []
seen = set()
for raw in raw_lines:
    rec = json.loads(raw)
    lid = ((rec.get('identity') or {}).get('lens_id') or '').upper()
    assert lid, 'Canonical record missing identity.lens_id'
    assert lid not in seen, f'Duplicate canonical Lens ID {lid}'
    seen.add(lid)
    ids.append(lid)
    records.append(rec)

sorted_ids = sorted(ids)
sorted_id_sha = hashlib.sha256(('\n'.join(sorted_ids) + '\n').encode('utf-8')).hexdigest()
assert sorted_id_sha == EXPECTED_SORTED_ID_SHA256, (
    f'Canonical identity set changed: expected {EXPECTED_SORTED_ID_SHA256}, found {sorted_id_sha}'
)

bits = base64.b64decode(TARGET_BITSET_B64)
assert len(bits) * 8 >= EXPECTED_RECORDS

target_ids = {
    lid for i, lid in enumerate(sorted_ids)
    if bits[i // 8] & (1 << (i % 8))
}
assert len(target_ids) == EXPECTED_TARGETS, f'Expected {EXPECTED_TARGETS} targets, found {len(target_ids)}'

# Validate all current decisions before changing anything.
conflicts = []
already_excluded = 0
undecided = 0
for rec in records:
    lid = rec['identity']['lens_id'].upper()
    if lid not in target_ids:
        continue
    rel = ((rec.get('screening') or {}).get('relevance'))
    if rel is None or (isinstance(rel, dict) and rel.get('decision') is None):
        undecided += 1
    elif isinstance(rel, dict) and rel.get('decision') == 'EXCLUDE':
        already_excluded += 1
    else:
        conflicts.append({'lens_id': lid, 'screening_relevance': rel})

assert not conflicts, f'Conflicting existing decisions for historical EXCLUDE targets: {json.dumps(conflicts[:20], ensure_ascii=False)}'
assert undecided + already_excluded == EXPECTED_TARGETS

now = datetime.now(timezone.utc).isoformat()
audit_rows = []
written = 0
preserved = 0

for rec in records:
    lid = rec['identity']['lens_id'].upper()
    if lid not in target_ids:
        continue
    screening = rec.setdefault('screening', {})
    previous = copy.deepcopy(screening.get('relevance'))
    if isinstance(previous, dict) and previous.get('decision') == 'EXCLUDE':
        preserved += 1
        action = 'existing_exclude_preserved'
    else:
        screening['relevance'] = copy.deepcopy(new_relevance)
        prov = rec.setdefault('provenance', {})
        prov['historical_excludes_reconciliation'] = {
            'source_file': 'EXCLUDES(3).ris',
            'decision': 'EXCLUDE',
            'matching_audit': {
                'source_records_verified': 5981,
                'match_basis_counts': {
                    'exact_lens_id': 5958,
                    'unique_doi': 5,
                    'unique_normalised_title': 18,
                },
                'unique_canonical_matches': 5977,
                'final_master_conflicts_excluded_from_target_set': 24,
                'safe_unique_exclusion_targets': 5953,
                'previously_reported_matches_not_reproduced': 4,
            },
            'reconciled_at': now,
            'workflow_run_id': os.environ.get('GITHUB_RUN_ID'),
        }
        written += 1
        action = 'historical_exclude_written'
    audit_rows.append({
        'lens_id': lid,
        'action': action,
        'previous_screening_relevance': previous,
        'resulting_screening_relevance': copy.deepcopy((rec.get('screening') or {}).get('relevance')),
    })

assert written + preserved == EXPECTED_TARGETS

tmp = records_path.with_suffix('.jsonl.tmp')
with tmp.open('w', encoding='utf-8') as f:
    for rec in records:
        f.write(json.dumps(rec, ensure_ascii=False, separators=(',', ':')) + '\n')

# Validate the result before replacing canonical.
verify_count = 0
verify_ids = set()
verified_target_excludes = 0
for line in tmp.open(encoding='utf-8'):
    rec = json.loads(line)
    verify_count += 1
    lid = ((rec.get('identity') or {}).get('lens_id') or '').upper()
    assert lid and lid not in verify_ids
    verify_ids.add(lid)
    if lid in target_ids:
        rel = ((rec.get('screening') or {}).get('relevance') or {})
        assert rel.get('decision') == 'EXCLUDE', f'Target {lid} is not EXCLUDE after reconciliation'
        verified_target_excludes += 1

assert verify_count == EXPECTED_RECORDS
assert len(verify_ids) == EXPECTED_RECORDS
assert verified_target_excludes == EXPECTED_TARGETS

tmp.replace(records_path)
digest = hashlib.sha256(records_path.read_bytes()).hexdigest()

manifest = json.loads(manifest_path.read_text(encoding='utf-8'))
assert manifest.get('record_count') == EXPECTED_RECORDS
manifest['created_at'] = now
manifest['records_sha256'] = digest
addition = (
    'Reconciled verified historical EXCLUDES(3).ris matches: 5,953 non-conflicting unique canonical records are now EXCLUDE; '
    '24 records also present in the final retained master were deliberately not targeted, and 4 previously reported matches remain unresolved.'
)
notes = manifest.get('notes') or ''
if addition not in notes:
    manifest['notes'] = (notes.rstrip() + ' ' + addition).strip()
manifest['historical_excludes_reconciliation'] = {
    'source_file': 'EXCLUDES(3).ris',
    'source_records_total': 7719,
    'source_records_verified_matched': 5981,
    'match_basis_counts': {
        'exact_lens_id': 5958,
        'unique_doi': 5,
        'unique_normalised_title': 18,
    },
    'unique_canonical_matches': 5977,
    'duplicate_source_matches_to_same_canonical_record': 4,
    'final_master_conflicts_not_overwritten': 24,
    'unique_exclusion_targets': EXPECTED_TARGETS,
    'new_exclude_decisions_written': written,
    'existing_exclude_decisions_preserved': preserved,
    'previously_reported_matches_not_reproduced': 4,
    'decision': 'EXCLUDE',
    'decision_source': 'historical_excludes_ris',
    'adjudication_date': ADJUDICATION_DATE,
    'workflow_run_id': os.environ.get('GITHUB_RUN_ID'),
}
manifest_path.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')

with audit_path.open('w', encoding='utf-8') as f:
    for row in audit_rows:
        f.write(json.dumps(row, ensure_ascii=False) + '\n')

archive_manifest = {
    'schema': 'living_evidence_map_historical_excludes_reconciliation_audit',
    'stage': '08_historical_excludes_reconciliation',
    'created_at': now,
    'canonical_record_count': EXPECTED_RECORDS,
    'canonical_sorted_lens_id_sha256': sorted_id_sha,
    'source_file': 'EXCLUDES(3).ris',
    'source_records_total': 7719,
    'source_records_verified_matched': 5981,
    'unique_canonical_matches': 5977,
    'final_master_conflicts_not_overwritten': 24,
    'unique_exclusion_targets': EXPECTED_TARGETS,
    'new_exclude_decisions_written': written,
    'existing_exclude_decisions_preserved': preserved,
    'previously_reported_matches_not_reproduced': 4,
    'canonical_records_sha256': digest,
    'workflow_run_id': os.environ.get('GITHUB_RUN_ID'),
}
archive_manifest_path.write_text(json.dumps(archive_manifest, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')

print(json.dumps({
    'record_count': EXPECTED_RECORDS,
    'verified_targets': EXPECTED_TARGETS,
    'new_exclude_decisions_written': written,
    'existing_exclude_decisions_preserved': preserved,
    'final_master_conflicts_not_overwritten': 24,
    'previously_reported_matches_not_reproduced': 4,
    'records_sha256': digest,
}, indent=2))
