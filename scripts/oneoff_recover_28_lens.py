import json
import os
import time
from pathlib import Path

import requests

IDS = [
    "012-639-887-533-230",
    "019-302-028-265-996",
    "021-120-599-540-909",
    "024-467-394-778-974",
    "035-193-855-089-850",
    "054-477-191-126-973",
    "061-696-741-811-996",
    "061-951-760-687-471",
    "062-797-037-307-031",
    "067-931-641-944-199",
    "068-184-595-919-637",
    "080-594-864-290-977",
    "093-075-864-485-763",
    "101-309-448-637-809",
    "113-151-351-905-385",
    "122-304-338-391-405",
    "124-264-127-561-979",
    "131-236-784-918-312",
    "134-977-553-604-428",
    "142-692-828-048-880",
    "144-473-705-890-157",
    "157-383-416-203-018",
    "161-812-654-416-50X",
    "174-207-366-005-817",
    "175-637-124-847-313",
    "176-822-536-033-86X",
    "180-207-561-404-407",
    "188-666-287-311-227",
]

assert len(IDS) == 28
assert len(set(IDS)) == 28

token = os.environ.get("LENS_API_TOKEN")
if not token:
    raise RuntimeError("LENS_API_TOKEN is required")

out = Path("outputs/oneoff_final_master_28_recovery")
out.mkdir(parents=True, exist_ok=True)

headers = {
    "Authorization": "Bearer " + token,
    "Content-Type": "application/json",
    "Accept": "application/json",
}
url = "https://api.lens.org/scholarly/search"


def post(payload):
    last = None
    for attempt in range(5):
        response = requests.post(url, headers=headers, json=payload, timeout=120)
        if response.status_code == 200:
            return response.json()
        if response.status_code == 204:
            return {"data": []}
        last = f"HTTP {response.status_code}: {response.text[:1000]}"
        if response.status_code == 429 or 500 <= response.status_code < 600:
            wait = response.headers.get("x-rate-limit-retry-after-seconds") or response.headers.get("Retry-After") or str(2 ** attempt)
            try:
                wait = min(60.0, float(wait))
            except Exception:
                wait = min(60.0, float(2 ** attempt))
            time.sleep(wait)
            continue
        raise RuntimeError(last)
    raise RuntimeError(f"Lens request failed after retries: {last}")


response = post({"query": {"terms": {"lens_id": IDS}}, "size": 100})
(out / "raw_exact_id_response.json").write_text(
    json.dumps(response, ensure_ascii=False, indent=2), encoding="utf-8"
)

returned = response.get("data", []) or []
by_id = {}
unexpected = []
requested = set(IDS)

for record in returned:
    lens_id = record.get("lens_id")
    if not lens_id:
        continue
    if lens_id not in requested:
        unexpected.append(lens_id)
        continue
    if lens_id in by_id:
        raise RuntimeError(f"Duplicate Lens result for {lens_id}")
    by_id[lens_id] = record

found_ids = [lens_id for lens_id in IDS if lens_id in by_id]
missing_ids = [lens_id for lens_id in IDS if lens_id not in by_id]

with (out / "records.jsonl").open("w", encoding="utf-8") as handle:
    for lens_id in found_ids:
        record = by_id[lens_id]
        wrapper = {
            "identity": {
                "lens_id": lens_id,
                "record_id": lens_id,
                "record_id_type": "lens_id",
            },
            "source": {"provider": "lens", "source_format": "lens_api_json"},
            "lens": {"raw_payload": record},
            "provenance": {"recovery": "final_master_missing_exact_lens_id"},
        }
        handle.write(json.dumps(wrapper, ensure_ascii=False, separators=(",", ":")) + "\n")

(out / "requested_ids.txt").write_text("\n".join(IDS) + "\n", encoding="utf-8")
(out / "found_ids.txt").write_text("\n".join(found_ids) + ("\n" if found_ids else ""), encoding="utf-8")
(out / "missing_ids.txt").write_text("\n".join(missing_ids) + ("\n" if missing_ids else ""), encoding="utf-8")

manifest = {
    "exact_ids_requested": len(IDS),
    "exact_ids_found": len(found_ids),
    "exact_ids_missing": len(missing_ids),
    "unexpected_ids_returned": unexpected,
    "canonical_modified": False,
}
(out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
print(json.dumps(manifest, indent=2))
