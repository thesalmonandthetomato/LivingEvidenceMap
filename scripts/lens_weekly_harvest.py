#!/usr/bin/env python3
import copy, csv, json, os, re
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

api_query = cfg.get("api_query")
if not isinstance(api_query, dict) or not isinstance(api_query.get("query"), dict):
    raise SystemExit("config/lens_search.json does not contain api_query.query as a JSON query object")

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

# Lens accepts a JSON Query DSL range query. Preserve the validated base query exactly
# and add created as an additional boolean filter rather than converting the whole
# JSON query object into a query-string expression.
query = copy.deepcopy(api_query["query"])
if not isinstance(query, dict) or not query:
    raise SystemExit("api_query.query must be a non-empty JSON query object")

if "bool" in query and isinstance(query["bool"], dict):
    bool_query = query["bool"]
    filters = bool_query.setdefault("filter", [])
    if isinstance(filters, dict):
        filters = [filters]
        bool_query["filter"] = filters
    if not isinstance(filters, list):
        raise SystemExit("api_query.query.bool.filter must be a list when present")
    filters.append({"range": {"created": {"gte": start_s, "lte": end_s}}})
else:
    query = {
        "bool": {
            "must": [query],
            "filter": [{"range": {"created": {"gte": start_s, "lte": end_s}}}]
        }
    }

page_size = 100
from_value = 0
all_records = []

audit_query = copy.deepcopy(query)
while True:
    payload_cfg = copy.deepcopy(api_query)
    payload_cfg["query"] = query
    payload_cfg["size"] = page_size
    payload_cfg["from"] = from_value
    payload = json.dumps(payload_cfg).encode("utf-8")
    req = Request(API_URL, data=payload, method="POST", headers={
        "Authorization": TOKEN,
        "Content-Type": "application/json",
        "Accept": "application/json",
    })
    try:
        with urlopen(req, timeout=120) as response:
            body = json.load(response)
            if response.status != 200:
                raise RuntimeError(f"Lens API HTTP {response.status}")
    except Exception as exc:
        print(f"Lens API request failed for window {start_s} to {end_s}", flush=True)
        raise

    records = body.get("data", [])
    total = int(body.get("total", 0))
    all_records.extend(records)
    print(f"Fetched {len(all_records)}/{total} records from Lens", flush=True)
    if not records or len(all_records) >= total:
        break
    from_value += len(records)

# Cheap within-update exact duplicate diagnostics. Do not apply fuzzy matching here:
# the production master deduplicator remains the authority for update-vs-master matching.
def norm(value):
    if value is None:
        return ""
    return re.sub(r"\s+", " ", str(value).strip().lower())

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
    "base_query": cfg.get("lens_ui_query"),
    "incremental_query": audit_query,
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
