#!/usr/bin/env python3
"""Run a non-mutating Lens harvest for an explicit diagnostic window."""
import csv, json, os, re, sys, time
from datetime import datetime, timezone
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen

API_URL = "https://api.lens.org/scholarly/search"
ROOT = Path(__file__).resolve().parents[1]
CONFIG = ROOT / "config/lens_search.json"
OUT = ROOT / "outputs/lens_diagnostic"
TOKEN = os.environ.get("LENS_API_TOKEN")
PAGE_SIZE = 500
SCROLL = "1m"

if not TOKEN:
    raise SystemExit("LENS_API_TOKEN secret is not set")
if len(sys.argv) != 3:
    raise SystemExit("Usage: lens_diagnostic_harvest.py FROM TO")

def parse_dt(v):
    return datetime.fromisoformat(v.replace("Z", "+00:00")).astimezone(timezone.utc)

def fmt(v):
    return v.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

start, end = parse_dt(sys.argv[1]), parse_dt(sys.argv[2])
if end <= start:
    raise SystemExit("Diagnostic end must be after start")

with CONFIG.open(encoding="utf-8") as f:
    cfg = json.load(f)
api_cfg = cfg.get("api_query")
if not isinstance(api_cfg, dict) or not isinstance(api_cfg.get("query"), dict):
    raise SystemExit("config/lens_search.json must contain api_query.query")
base_query = api_cfg["query"]
include = api_cfg.get("include", ["lens_id","title","abstract","created","date_published","year_published","publication_type","external_ids","keywords"])
query = {"bool": {"must": [base_query], "filter": [{"range": {"created": {"gte": fmt(start), "lte": fmt(end)}}}]}}

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
records, total = [], 0
while True:
    body = request_json(payload)
    if body is None: break
    page = body.get("data", [])
    total = int(body.get("total", total))
    records.extend(page)
    print(f"Fetched {len(records)}/{total} records from Lens", flush=True)
    if not page or len(records) >= total: break
    scroll_id = body.get("scroll_id")
    if not scroll_id: raise SystemExit("Lens API returned more records but no scroll_id")
    payload = {"scroll_id": scroll_id, "scroll": SCROLL, "include": include}

def norm(v): return "" if v is None else re.sub(r"\s+", " ", str(v).strip().lower())
def key(rec):
    lens, doi, title = norm(rec.get("lens_id")), norm(rec.get("doi")), norm(rec.get("title"))
    return ("lens:" + lens) if lens else (("doi:" + doi) if doi else ("title:" + title) if title else "")

seen, unique = set(), []
for rec in records:
    k = key(rec)
    if k and k in seen: continue
    if k: seen.add(k)
    unique.append(rec)

OUT.mkdir(parents=True, exist_ok=True)
stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
json_path = OUT / f"lens_diagnostic_{stamp}.json"
csv_path = OUT / f"lens_diagnostic_{stamp}.csv"
manifest_path = OUT / f"lens_diagnostic_{stamp}_manifest.json"
json_path.write_text(json.dumps(unique, ensure_ascii=False, indent=2), encoding="utf-8")
fields = sorted({k for r in unique for k in r.keys()})
with csv_path.open("w", newline="", encoding="utf-8") as f:
    w = csv.DictWriter(f, fieldnames=fields, extrasaction="ignore")
    w.writeheader(); w.writerows(unique)
manifest = {"status": "records_found" if unique else "no_records", "diagnostic": True, "window_start": fmt(start), "window_end": fmt(end), "total_matching_window": total, "raw_records_retrieved": len(records), "unique_records_written": len(unique), "production_state_changed": False, "master_changed": False}
manifest_path.write_text(json.dumps(manifest, indent=2), encoding="utf-8")
print(f"Window: {fmt(start)} to {fmt(end)}")
print(f"Lens matching records: {total}")
print(f"Unique records written: {len(unique)}")
print("Production state: UNCHANGED")
print("Master evidence base: UNCHANGED")
