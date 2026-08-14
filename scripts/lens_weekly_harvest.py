#!/usr/bin/env python3
import csv, json, os, re, sys
from datetime import datetime, timedelta, timezone
from pathlib import Path
from urllib.request import Request, urlopen

API_URL = "https://api.lens.org/scholarly/search"
CONFIG = Path("config/lens_search.json")
STATE = Path("outputs/lens_harvest/state.json")
OUT = Path("outputs/lens_harvest")
TOKEN = os.environ.get("LENS_API_TOKEN")
OVERLAP_DAYS = int(os.environ.get("OVERLAP_DAYS", "7"))

if not TOKEN:
    raise SystemExit("LENS_API_TOKEN secret is not set")

with CONFIG.open(encoding="utf-8") as f:
    cfg = json.load(f)

base_query = cfg["api_query"]["query"] if isinstance(cfg.get("api_query"), dict) else None
if not base_query:
    raise SystemExit("config/lens_search.json does not contain api_query.query")

OUT.mkdir(parents=True, exist_ok=True)

now = datetime.now(timezone.utc)
previous = None
if STATE.exists():
    try:
        previous = json.loads(STATE.read_text(encoding="utf-8")).get("last_successful_created")
    except json.JSONDecodeError:
        previous = None

if previous:
    try:
        start = datetime.fromisoformat(previous.replace("Z", "+00:00")) - timedelta(days=OVERLAP_DAYS)
    except ValueError:
        start = now - timedelta(days=OVERLAP_DAYS)
else:
    # First run is a bounded seven-day test window, not a full 21k-record download.
    start = now - timedelta(days=OVERLAP_DAYS)

start_s = start.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
end_s = now.strftime("%Y-%m-%dT%H:%M:%SZ")

# Lens query-string range syntax; retain the base search exactly and constrain created.
query = f"({base_query}) AND created:[{start_s} TO {end_s}]"

page_size = 100
from_value = 0
all_records = []

while True:
    payload_cfg = dict(cfg["api_query"])
    payload_cfg["query"] = query
    payload_cfg["size"] = page_size
    payload_cfg["from"] = from_value
    payload = json.dumps(payload_cfg).encode("utf-8")
    req = Request(API_URL, data=payload, method="POST", headers={
        "Authorization": TOKEN,
        "Content-Type": "application/json",
        "Accept": "application/json",
    })
    with urlopen(req, timeout=120) as response:
        body = json.load(response)
        if response.status != 200:
            raise RuntimeError(f"Lens API HTTP {response.status}")

    records = body.get("data", [])
    total = int(body.get("total", 0))
    all_records.extend(records)
    print(f"Fetched {len(all_records)}/{total} records from Lens")
    if not records or len(all_records) >= total:
        break
    from_value += len(records)

# Cheap within-update exact duplicate diagnostics. Do not apply fuzzy matching here:
# the production master deduplicator remains the authority for update-vs-master matching.
def norm(value):
    if value is None:
        return ""
    return re.sub(r"\\s+", " ", str(value).strip().lower())

def key(rec):
    lens_id = norm(rec.get("lens_id"))
    doi = norm(rec.get("doi"))
    title = norm(rec.get("title"))
    return ("lens:" + lens_id) if lens_id else (("doi:" + doi) if doi else ("title:" + title) if title else "")

seen = set()
unique = []
dup_count = 0
for rec in all_records:
    k = key(rec)
    if k and k in seen:
        dup_count += 1
        continue
    if k:
        seen.add(k)
    unique.append(rec)

stamp = now.strftime("%Y%m%dT%H%M%SZ")
json_path = OUT / f"lens_increment_{stamp}.json"
csv_path = OUT / f"lens_increment_{stamp}.csv"
manifest_path = OUT / f"lens_increment_{stamp}_manifest.json"

json_path.write_text(json.dumps(unique, ensure_ascii=False, indent=2), encoding="utf-8")

fields = sorted({k for r in unique for k in r.keys()})
with csv_path.open("w", newline="", encoding="utf-8") as f:
    writer = csv.DictWriter(f, fieldnames=fields, extrasaction="ignore")
    writer.writeheader()
    writer.writerows(unique)

manifest = {
    "retrieved_at": now.isoformat(),
    "window_start": start_s,
    "window_end": end_s,
    "previous_last_successful_created": previous,
    "base_query": base_query,
    "total_matching_window": total,
    "raw_records_retrieved": len(all_records),
    "within_update_duplicates_removed": dup_count,
    "unique_records_written": len(unique),
    "note": "This workflow only harvests and performs within-update exact deduplication. Existing master comparison and annotation remain downstream steps."
}
manifest_path.write_text(json.dumps(manifest, indent=2), encoding="utf-8")

# Only advance checkpoint after the complete API retrieval and artifact writes succeeded.
STATE.write_text(json.dumps({
    "last_successful_created": end_s,
    "updated_at": now.isoformat()
}, indent=2), encoding="utf-8")

print(f"Raw records: {len(all_records)}")
print(f"Within-update duplicates removed: {dup_count}")
print(f"Unique records: {len(unique)}")
print(f"Window: {start_s} to {end_s}")
print(f"Checkpoint advanced to: {end_s}")
