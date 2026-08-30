import copy
import hashlib
import json
import os
from datetime import datetime, timezone
from pathlib import Path

records_path = Path("data/canonical/current/repair/records.jsonl")
manifest_path = Path("data/canonical/current/repair/manifest.json")
aliases_path = Path("data/canonical/archive/repair/06_lens_id_rekey_reconciliation/lens_id_aliases.jsonl")
recovered_path = Path(os.environ.get("RECOVERED_17_PATH", "/tmp/recovery/records.jsonl"))
archive_dir = Path("data/canonical/archive/repair/07_final_master_reconciliation")
archive_dir.mkdir(parents=True, exist_ok=True)
audit_path = archive_dir / "canonical_reconciliation_audit.jsonl"
archive_manifest_path = archive_dir / "manifest.json"

EXPECTED_BEFORE = 22131
EXPECTED_APPEND = 17
EXPECTED_REKEY = 11
EXPECTED_AFTER = 22148
ADJUDICATION_DATE = "2026-08-30"
SOURCE_RUN_ID = 33310473136
SOURCE_ARTIFACT_ID = 9731817905

new_relevance = {
    "decision": "RETAIN",
    "decision_source": "historical_final_master",
    "adjudication_set": "historical_master_reconciliation",
    "adjudication_date": ADJUDICATION_DATE,
    "decision_basis": "present_in_final_historical_master",
}

aliases = []
for line in aliases_path.read_text(encoding="utf-8").splitlines():
    if line.strip():
        aliases.append(json.loads(line))
assert len(aliases) == EXPECTED_REKEY, f"Expected {EXPECTED_REKEY} aliases, found {len(aliases)}"
current_to_historical = {}
for a in aliases:
    old = a["historical_lens_id"].upper()
    cur = a["current_lens_id"].upper()
    assert cur not in current_to_historical, f"Duplicate current alias ID {cur}"
    current_to_historical[cur] = old

recovered = []
for line in recovered_path.read_text(encoding="utf-8").splitlines():
    if line.strip():
        recovered.append(json.loads(line))
assert len(recovered) == EXPECTED_APPEND, f"Expected {EXPECTED_APPEND} recovered records, found {len(recovered)}"
recovered_ids = []
for rec in recovered:
    lid = ((rec.get("identity") or {}).get("lens_id") or "").upper()
    assert lid, "Recovered record missing identity.lens_id"
    assert lid not in recovered_ids, f"Duplicate recovered Lens ID {lid}"
    recovered_ids.append(lid)

raw_lines = records_path.read_text(encoding="utf-8").splitlines()
assert len(raw_lines) == EXPECTED_BEFORE, f"Expected {EXPECTED_BEFORE} canonical records, found {len(raw_lines)}"

records = []
seen = set()
rekey_hits = 0
audit_rows = []

for raw in raw_lines:
    rec = json.loads(raw)
    lid = ((rec.get("identity") or {}).get("lens_id") or "").upper()
    assert lid, "Canonical record missing identity.lens_id"
    assert lid not in seen, f"Duplicate canonical Lens ID {lid}"
    seen.add(lid)

    if lid in current_to_historical:
        rekey_hits += 1
        historical_id = current_to_historical[lid]
        screening = rec.setdefault("screening", {})
        assert isinstance(screening, dict), f"screening is not an object for {lid}"
        previous = copy.deepcopy(screening.get("relevance"))
        if previous is not None:
            assert isinstance(previous, dict), f"screening.relevance is not an object for {lid}"
            assert previous.get("decision") in (None, "RETAIN"), (
                f"Conflicting relevance decision for re-keyed record {lid}: {previous}"
            )
        screening["relevance"] = copy.deepcopy(new_relevance)

        prov = rec.setdefault("provenance", {})
        assert isinstance(prov, dict), f"provenance is not an object for {lid}"
        prov["historical_final_master_reconciliation"] = {
            "historical_lens_id": historical_id,
            "current_lens_id": lid,
            "identity_basis": "verified_lens_id_rekey",
            "source_workflow_run_id": SOURCE_RUN_ID,
            "source_artifact_id": SOURCE_ARTIFACT_ID,
        }

        audit_rows.append({
            "action": "update_existing_rekeyed_record",
            "historical_lens_id": historical_id,
            "canonical_lens_id": lid,
            "previous_screening_relevance": previous,
            "new_screening_relevance": copy.deepcopy(new_relevance),
        })
    records.append(rec)

assert rekey_hits == EXPECTED_REKEY, f"Expected {EXPECTED_REKEY} re-keyed canonical matches, found {rekey_hits}"
assert not (set(recovered_ids) & seen), f"Recovered IDs already exist in canonical: {sorted(set(recovered_ids) & seen)}"

def get_doi(raw_payload):
    for x in raw_payload.get("external_ids") or []:
        if isinstance(x, dict) and str(x.get("type", "")).lower() == "doi" and x.get("value"):
            return x["value"]
    return None

for wrapper in recovered:
    lid = wrapper["identity"]["lens_id"].upper()
    raw = ((wrapper.get("lens") or {}).get("raw_payload") or {})
    assert raw.get("lens_id", "").upper() == lid, f"Recovered raw payload Lens ID mismatch for {lid}"

    rec = copy.deepcopy(wrapper)
    rec["canonical"] = {
        "record_id": lid,
        "lens_id": lid,
        "title": raw.get("title"),
        "authors": raw.get("authors") or [],
        "year": raw.get("year_published"),
        "source": raw.get("source"),
        "doi": get_doi(raw),
        "abstract": raw.get("abstract"),
    }
    prov = rec.setdefault("provenance", {})
    prov["historical_final_master_reconciliation"] = {
        "historical_lens_id": lid,
        "current_lens_id": lid,
        "identity_basis": "exact_lens_id_recovered_from_lens_api",
        "source_workflow_run_id": SOURCE_RUN_ID,
        "source_artifact_id": SOURCE_ARTIFACT_ID,
    }
    rec["screening"] = {"relevance": copy.deepcopy(new_relevance)}
    records.append(rec)
    seen.add(lid)
    audit_rows.append({
        "action": "append_recovered_record",
        "historical_lens_id": lid,
        "canonical_lens_id": lid,
        "previous_screening_relevance": None,
        "new_screening_relevance": copy.deepcopy(new_relevance),
    })

assert len(records) == EXPECTED_AFTER
assert len(seen) == EXPECTED_AFTER
assert len(audit_rows) == EXPECTED_REKEY + EXPECTED_APPEND

tmp = records_path.with_suffix(".jsonl.tmp")
with tmp.open("w", encoding="utf-8") as f:
    for rec in records:
        f.write(json.dumps(rec, ensure_ascii=False, separators=(",", ":")) + "\n")

verify_count = 0
verify_ids = set()
verified_retain = 0
for line in tmp.open(encoding="utf-8"):
    rec = json.loads(line)
    verify_count += 1
    lid = ((rec.get("identity") or {}).get("lens_id") or "").upper()
    assert lid and lid not in verify_ids
    verify_ids.add(lid)
    if lid in current_to_historical or lid in recovered_ids:
        rel = ((rec.get("screening") or {}).get("relevance") or {})
        assert rel == new_relevance, f"Incorrect RETAIN decision for {lid}: {rel}"
        verified_retain += 1

assert verify_count == EXPECTED_AFTER
assert len(verify_ids) == EXPECTED_AFTER
assert verified_retain == EXPECTED_REKEY + EXPECTED_APPEND

tmp.replace(records_path)
digest = hashlib.sha256(records_path.read_bytes()).hexdigest()

manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
assert manifest.get("record_count") == EXPECTED_BEFORE, f"Unexpected manifest record count: {manifest.get('record_count')}"
manifest["created_at"] = datetime.now(timezone.utc).isoformat()
manifest["record_count"] = EXPECTED_AFTER
manifest["records_sha256"] = digest
addition = (
    "Reconciled the final historical master against current Lens identities: "
    "11 existing canonical records received historical RETAIN decisions via verified Lens-ID re-key mappings, "
    "and 17 exact Lens records were recovered and appended with historical RETAIN decisions."
)
notes = manifest.get("notes") or ""
if addition not in notes:
    manifest["notes"] = (notes.rstrip() + " " + addition).strip()
manifest["final_master_reconciliation"] = {
    "historical_master_lens_records_previously_unaccounted": 28,
    "existing_rekeyed_records_updated": EXPECTED_REKEY,
    "recovered_records_appended": EXPECTED_APPEND,
    "screening_decision": "RETAIN",
    "decision_source": "historical_final_master",
    "adjudication_set": "historical_master_reconciliation",
    "adjudication_date": ADJUDICATION_DATE,
    "source_lens_workflow_run_id": SOURCE_RUN_ID,
    "source_lens_artifact_id": SOURCE_ARTIFACT_ID,
    "repair_workflow_run_id": os.environ.get("GITHUB_RUN_ID"),
}
manifest_path.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

with audit_path.open("w", encoding="utf-8") as f:
    for row in audit_rows:
        f.write(json.dumps(row, ensure_ascii=False) + "\n")

archive_manifest = {
    "schema": "living_evidence_map_final_master_reconciliation_audit",
    "stage": "07_final_master_reconciliation",
    "created_at": datetime.now(timezone.utc).isoformat(),
    "records_reconciled": 28,
    "existing_rekeyed_records_updated": EXPECTED_REKEY,
    "recovered_records_appended": EXPECTED_APPEND,
    "decision": "RETAIN",
    "decision_source": "historical_final_master",
    "canonical_record_count_before": EXPECTED_BEFORE,
    "canonical_record_count_after": EXPECTED_AFTER,
    "canonical_records_sha256": digest,
    "source_lens_workflow_run_id": SOURCE_RUN_ID,
    "source_lens_artifact_id": SOURCE_ARTIFACT_ID,
    "repair_workflow_run_id": os.environ.get("GITHUB_RUN_ID"),
}
archive_manifest_path.write_text(json.dumps(archive_manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

print(json.dumps({
    "before_count": EXPECTED_BEFORE,
    "rekeyed_existing_updated": EXPECTED_REKEY,
    "recovered_appended": EXPECTED_APPEND,
    "after_count": EXPECTED_AFTER,
    "unique_lens_ids": len(verify_ids),
    "retain_decisions_verified": verified_retain,
    "records_sha256": digest,
}, indent=2))
