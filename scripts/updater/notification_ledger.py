#!/usr/bin/env python3
"""Check and record durable Workflow 03 human-review notification state."""
import argparse, json, os
from datetime import datetime, timezone
from pathlib import Path


def utc_now():
    return datetime.now(timezone.utc).isoformat()


def load_json(path, default):
    p = Path(path)
    if not p.exists():
        return default
    return json.loads(p.read_text(encoding="utf-8"))


def save_json(path, value):
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def check(state_path, ledger_path, output_path):
    state = load_json(state_path, {})
    ledger = load_json(ledger_path, {"version": 1, "sent": []})
    fingerprint = state.get("notification_fingerprint")
    pending_count = int(state.get("pending_count") or 0)
    sent = ledger.get("sent") or []
    already_sent = bool(fingerprint) and any(x.get("fingerprint") == fingerprint for x in sent)
    should_send = pending_count > 0 and bool(fingerprint) and not already_sent
    result = {
        "notification_fingerprint": fingerprint,
        "pending_count": pending_count,
        "already_sent": already_sent,
        "should_send": should_send,
    }
    save_json(output_path, result)


def record(state_path, ledger_path, run_id):
    state = load_json(state_path, {})
    ledger = load_json(ledger_path, {"version": 1, "sent": []})
    fingerprint = state.get("notification_fingerprint")
    pending_count = int(state.get("pending_count") or 0)
    case_ids = state.get("pending_review_case_ids") or []
    if pending_count <= 0 or not fingerprint:
        raise SystemExit("Cannot record a notification with no pending cases or fingerprint")
    sent = ledger.setdefault("sent", [])
    if not any(x.get("fingerprint") == fingerprint for x in sent):
        sent.append({
            "fingerprint": fingerprint,
            "pending_count": pending_count,
            "pending_review_case_ids": case_ids,
            "sent_at": utc_now(),
            "github_run_id": str(run_id) if run_id else None,
        })
    save_json(ledger_path, ledger)


def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="command", required=True)
    c = sub.add_parser("check")
    c.add_argument("--state", required=True)
    c.add_argument("--ledger", required=True)
    c.add_argument("--output", required=True)
    r = sub.add_parser("record")
    r.add_argument("--state", required=True)
    r.add_argument("--ledger", required=True)
    r.add_argument("--run-id", default=os.getenv("GITHUB_RUN_ID", ""))
    a = p.parse_args()
    if a.command == "check":
        check(a.state, a.ledger, a.output)
    else:
        record(a.state, a.ledger, a.run_id)


if __name__ == "__main__":
    main()
