#!/usr/bin/env python3
import argparse, csv, datetime as dt, json, os, time, urllib.error, urllib.parse, urllib.request
import xml.etree.ElementTree as ET

UA = "LivingEvidenceMap W00 search scoping"

def args():
    p = argparse.ArgumentParser()
    p.add_argument("--plan", required=True)
    p.add_argument("--lens-config", default="config/lens_search.json")
    p.add_argument("--ebsco-config", default="config/workflow00_ebsco_sources.json")
    p.add_argument("--source", required=True)
    p.add_argument("--output-csv", required=True)
    p.add_argument("--output-json", required=True)
    return p.parse_args()

def load_json(path):
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)

def request_json(url, label, headers=None, params=None, payload=None):
    if params:
        url += ("&" if "?" in url else "?") + urllib.parse.urlencode(params)
    data = None if payload is None else json.dumps(payload, separators=(",", ":")).encode("utf-8")
    hdr = {"User-Agent": UA, "Accept": "application/json"}
    if headers: hdr.update(headers)
    if data is not None: hdr["Content-Type"] = "application/json"
    return json.loads(request_bytes(url, label, hdr, data).decode("utf-8"))

def request_bytes(url, label, headers=None, data=None):
    last = None
    for attempt in range(6):
        try:
            req = urllib.request.Request(url, data=data, headers=headers or {}, method="POST" if data is not None else "GET")
            with urllib.request.urlopen(req, timeout=90) as resp:
                return resp.read()
        except urllib.error.HTTPError as e:
            body = e.read(1000).decode("utf-8", "replace")
            last = f"{label} HTTP {e.code}: {body}"
            if e.code != 429 and e.code < 500:
                raise RuntimeError(last)
        except Exception as e:
            last = str(e)
        if attempt < 5:
            time.sleep(min(30, 2 ** attempt))
    raise RuntimeError(f"{label} count request failed after 6 attempts: {last}")

def scalar_int(x, label):
    try:
        return int(x)
    except Exception:
        raise RuntimeError(f"{label} response did not contain a valid total")

def safe_count(label, fn):
    print(f"Counting {label}...", flush=True)
    try:
        n = int(fn())
        print(f"{label}: {n}", flush=True)
        return n, "counted live"
    except Exception as e:
        print(f"{label} FAILED: {e}", flush=True)
        return None, f"API count failed: {e}"

def count_lens(query, lens_config):
    token = os.environ.get("LENS_API_TOKEN", "")
    if not token: raise RuntimeError("LENS_API_TOKEN is required")
    cfg = load_json(lens_config)
    cfg["api_query"]["query"]["bool"]["must"][0]["query_string"]["query"] = query
    x = request_json(
        "https://api.lens.org/scholarly/search", "Lens",
        headers={"Authorization": f"Bearer {token}"},
        payload={"query": cfg["api_query"]["query"], "size": 1}
    )
    return scalar_int(x.get("total"), "Lens")

def count_scopus(query):
    token = os.environ.get("SCOPUS_API_TOKEN", "").strip()
    inst = os.environ.get("SCOPUS_INSTTOKEN", "").strip()
    if not token: raise RuntimeError("SCOPUS_API_TOKEN is required")
    if not inst: raise RuntimeError("SCOPUS_INSTTOKEN is required")
    x = request_json(
        "https://api.elsevier.com/content/search/scopus", "Scopus",
        headers={"X-ELS-APIKey": token, "X-ELS-Insttoken": inst},
        params={"query": query, "start": 0, "count": 1, "view": "STANDARD"}
    )
    return scalar_int(x.get("search-results", {}).get("opensearch:totalResults"), "Scopus")

def count_openalex(query):
    token = os.environ.get("OPENALEX_API_KEY", "") or os.environ.get("OPENALEX_API_TOKEN", "")
    if not token: raise RuntimeError("OPENALEX_API_KEY or OPENALEX_API_TOKEN is required")
    x = request_json(
        "https://api.openalex.org/", "OpenAlex",
        headers={"Authorization": f"Bearer {token}"},
        params={"oql": query, "per-page": 1, "cursor": "*"}
    )
    return scalar_int(x.get("meta", {}).get("count"), "OpenAlex")

def count_epmc(query, label):
    x = request_json(
        "https://www.ebi.ac.uk/europepmc/webservices/rest/search", label,
        params={"query": query, "format": "json", "resultType": "core", "pageSize": 1, "cursorMark": "*", "synonym": "false"}
    )
    return scalar_int(x.get("hitCount"), label)

def count_wos(query):
    token = os.environ.get("WOS_STARTER_API", "")
    if not token: raise RuntimeError("WOS_STARTER_API is required")
    x = request_json(
        "https://api.clarivate.com/apis/wos-starter/v1/documents", "Web of Science",
        headers={"X-ApiKey": token},
        params={"q": query, "db": "WOS", "limit": 1, "page": 1}
    )
    return scalar_int(x.get("metadata", {}).get("total"), "Web of Science")

def count_ebsco(source_slug, query, cfg):
    uid = os.environ.get("EBSCO_EHOST_UID", "").strip()
    pwd = os.environ.get("EBSCO_EHOST_PWD", "").strip()
    if not uid or not pwd: raise RuntimeError("EBSCO_EHOST_UID and EBSCO_EHOST_PWD are required")
    src = cfg["sources"].get(source_slug)
    if src is None: raise RuntimeError(f"Unknown EBSCO source: {source_slug}")
    url = "https://eit.ebscohost.com/Services/SearchService.asmx/Search?" + urllib.parse.urlencode({
        "prof": uid, "pwd": pwd, "authType": "profile", "db": src["db_code"],
        "query": query, "format": "detailed", "startrec": "1", "numrec": "1"
    })
    root = ET.fromstring(request_bytes(url, src["display_name"], {"User-Agent": UA}))
    vals = []
    for node in root.iter():
        if node.tag.split("}")[-1] == "Hits" and node.text:
            try: vals.append(int(node.text.strip()))
            except ValueError: pass
    if not vals: raise RuntimeError(f"{src['display_name']} response did not contain Hits")
    return vals[0]

def main():
    a = args()
    plan = load_json(a.plan)
    cfg = load_json(a.ebsco_config)
    q = plan.get("source_queries", {})
    src = a.source.strip()
    ebsco_sources = list(cfg.get("sources", {}).keys())
    live_sources = ["lens","scopus","openalex","agricola","pubmed","ethos","cba","epmc_preprints","wos"] + ebsco_sources
    if src not in live_sources:
        raise SystemExit(f"Unknown live scoping source: {src}")
    if not str(q.get(src, "")).strip():
        raise SystemExit(f"Search plan missing source query: {src}")

    label, fn = None, None
    if src == "lens": label, fn = "The Lens", lambda: count_lens(str(q[src]), a.lens_config)
    elif src == "scopus": label, fn = "Scopus", lambda: count_scopus(str(q[src]))
    elif src == "openalex": label, fn = "OpenAlex", lambda: count_openalex(str(q[src]))
    elif src == "agricola": label, fn = "AGRICOLA", lambda: count_epmc(str(q[src]), "AGRICOLA/Europe PMC")
    elif src == "pubmed": label, fn = "PubMed/MEDLINE", lambda: count_epmc(str(q[src]), "PubMed/MEDLINE via Europe PMC")
    elif src == "ethos": label, fn = "EThOS", lambda: count_epmc(str(q[src]), "EThOS via Europe PMC")
    elif src == "cba": label, fn = "Chinese Biological Abstracts", lambda: count_epmc(str(q[src]), "Chinese Biological Abstracts via Europe PMC")
    elif src == "epmc_preprints": label, fn = "Europe PMC preprints", lambda: count_epmc(str(q[src]), "Europe PMC preprints")
    elif src == "wos": label, fn = "Web of Science Core Collection", lambda: count_wos(str(q[src]))
    else:
        label = str(cfg["sources"][src]["display_name"])
        fn = lambda: count_ebsco(src, str(q[src]), cfg)

    hits, status = safe_count(label, fn)
    today = dt.datetime.now(dt.timezone.utc).date().isoformat()
    row = {
        "source": label, "access_mode": "API count", "search_date": today,
        "hits": "" if hits is None else hits, "status": status, "source_slug": src
    }
    os.makedirs(os.path.dirname(a.output_csv), exist_ok=True)
    with open(a.output_csv, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=["source","access_mode","search_date","hits","status","source_slug"])
        w.writeheader(); w.writerow(row)

    out = {
        "schema": "living-evidence-map-workflow00-search-scoping-v1",
        "workflow": "00_search_scoping",
        "status": "success",
        "counted_at_utc": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "search_date": today,
        "search_input_path": plan.get("input_path"),
        "original_search_string": plan.get("original_search_string"),
        "normalised_search_string": plan.get("normalised_search_string"),
        "boolean_validation": plan.get("validation"),
        "source_queries": q,
        "result_policy": "Counts only. No search-result records or raw API responses are written to disk.",
        "counts": [{
            "source": label, "source_slug": src, "access_mode": "API count",
            "search_date": today, "hits": hits, "status": status
        }]
    }
    with open(a.output_json, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, indent=2)
        f.write("\n")
    print("PASS: Workflow 00 search scoping count complete; no result records persisted.")

if __name__ == "__main__":
    main()
