#!/usr/bin/env python3
import csv, json, os, re, time
from datetime import datetime, timedelta, timezone
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen

API_URL = "https://api.lens.org/scholarly/search"
CONFIG = Path("config/lens_search.json")
STATE = Path("state/lens_weekly_harvest.json")
OUT = Path("outputs/lens_harvest")
TOKEN = os.environ.get("LENS_API_TOKEN")
OVERLAP_DAYS = int(os.environ.get("OVERLAP_DAYS", "7"))
PAGE_SIZE = 1000
SCROLL = "1m"

if not TOKEN:
    raise SystemExit("LENS_API_TOKEN secret is not set")
with CONFIG.open(encoding="utf-8") as f:
    cfg = json.load(f)
api_cfg = cfg.get("api_query")
if not isinstance(api_cfg, dict) or not isinstance(api_cfg.get("query"), dict):
    raise SystemExit("config/lens_search.json must contain api_query.query as a JSON query object")
base_query = api_cfg["query"]
include = api_cfg.get("include", ["lens_id", "title", "abstract", "created", "date_published", "year_published", "publication_type", "external_ids", "keywords"])
OUT.mkdir(parents=True, exist_ok=True)
STATE.parent.mkdir(parents=True, exist_ok=True)
now = datetime.now(timezone.utc)
previous = None
if STATE.exists():
    try:
        previous = json.loads(STATE.read_text(encoding="utf-8")).get("last_successful_created")
    except json.JSONDecodeError:
        pass
if previous:
    try:
        start = datetime.fromisoformat(previous.replace("Z", "+00:00")) - timedelta(days=OVERLAP_DAYS)
    except ValueError:
        start = now - timedelta(days=OVERLAP_DAYS)
else:
    start = now - timedelta(days=OVERLAP_DAYS)
start_s = start.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
end_s = now.strftime("%Y-%m-%dT%H:%M:%SZ")
query = {"bool": {"must": [base_query], "filter": [{"range": {"created": {"gte": start_s, "lte": end_s}}}]}}

def request_json(payload):
    req = Request(API_URL, data=json.dumps(payload).encode("utf-8"), method="POST", headers={"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json", "Accept": "application/json"})
    for attempt in range(4):
        try:
            with urlopen(req, timeout=120) as response:
                if response.status == 204:
                    return None
                return json.load(response)
        except HTTPError as exc:
            if exc.code == 429 and attempt < 3:
                raw = exc.headers.get("x-rate-limit-retry-after-seconds") or exc.headers.get("Retry-After") or "10"
                try: delay = max(2, int(float(raw)))
                except ValueError: delay = 10
                print(f"Rate limited; sleeping {delay}s", flush=True)
                time.sleep(delay)
                continue
            detail = exc.read().decode("utf-8", errors="replace")
            raise SystemExit(f"Lens API HTTP {exc.code}: {detail[:1000]}") from exc

payload = {"query": query, "size": PAGE_SIZE, "scroll": SCROLL, "include": include}
all_records, total = [], 0
while True:
    body = request_json(payload)
    if body is None: break
    records = body.get("data", [])
    total = int(body.get("total", total))
    all_records.extend(records)
    print(f"Fetched {len(all_records)}/{total} records from Lens", flush=True)
    if not records or len(all_records) >= total: break
    scroll_id = body.get("scroll_id")
    if not scroll_id: raise SystemExit("Lens API returned more records but no scroll_id")
    payload = {"scroll_id": scroll_id, "scroll": SCROLL, "include": include}

def norm(v): return "" if v is None else re.sub(r"\s+", " ", str(v).strip().lower())
def key(rec):
    lens = norm(rec.get("lens_id")); doi = norm(rec.get("doi")); title = norm(rec.get("title"))
    return ("lens:"+lens) if lens else (("doi:"+doi) if doi else ("title:"+title) if title else "")
seen, unique = set(), []
dup_count = 0
for rec in all_records:
    k = key(rec)
    if k and k in seen:
        dup_count += 1; continue
    if k: seen.add(k)
    unique.append(rec)
stamp = now.strftime("%Y%m%dT%H%M%SZ")
json_path = OUT / f"lens_increment_{stamp}.json"
csv_path = OUT / f"lens_increment_{stamp}.csv"
manifest_path = OUT / f"lens_increment_{stamp}_manifest.json"
json_path.write_text(json.dumps(unique, ensure_ascii=False, indent=2), encoding="utf-8")
fields = sorted({k for r in unique for k in r.keys()})
with csv_path.open("w", newline="", encoding="utf-8") as f:
    w = csv.DictWriter(f, fieldnames=fields, extrasaction="ignore"); w.writeheader(); w.writerows(unique)
manifest = {"retrieved_at": now.isoformat(), "window_start": start_s, "window_end": end_s, "previous_last_successful_created": previous, "base_query": base_query, "publication_type_exclusions": cfg.get("publication_type_exclusions", []), "total_matching_window": total, "raw_records_retrieved": len(all_records), "within_update_duplicates_removed": dup_count, "unique_records_written": len(unique), "pagination": "cursor"}
manifest_path.write_text(json.dumps(manifest, indent=2), encoding="utf-8")
STATE.write_text(json.dumps({"last_successful_created": end_s, "updated_at": now.isoformat()}, indent=2)+"\n", encoding="utf-8")
print(f"Raw records: {len(all_records)}")
print(f"Within-update duplicates removed: {dup_count}")
print(f"Unique records: {len(unique)}")
print(f"Window: {start_s} to {end_s}")
print(f"Checkpoint advanced to: {end_s}")
