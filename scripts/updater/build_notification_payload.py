#!/usr/bin/env python3
"""Build a deterministic email notification payload for pending human review."""
import argparse, hashlib, json, os
from pathlib import Path

DEFAULT_RECIPIENT = "nealhaddaway@gmail.com"
CHATGPT_URL = "https://chatgpt.com/"


def queue_fingerprint(case_ids):
    material = "\n".join(sorted(case_ids)).encode("utf-8")
    return hashlib.sha256(material).hexdigest()


def run(manifest_path, output_path, repository, run_id, recipient, artifact_url=None):
    manifest = json.loads(Path(manifest_path).read_text(encoding="utf-8"))
    cases = manifest.get("cases") or []
    case_ids = [c.get("review_case_id") for c in cases if c.get("review_case_id")]
    fingerprint = queue_fingerprint(case_ids)
    pending_count = int(manifest.get("pending_count") or len(case_ids))
    run_url = f"https://github.com/{repository}/actions/runs/{run_id}" if repository and run_id else None
    payload = {
        "recipient": recipient,
        "subject": f"LivingEvidenceMap: {pending_count} human review case{'s' if pending_count != 1 else ''}",
        "pending_count": pending_count,
        "queue_fingerprint": fingerprint,
        "review_case_ids": sorted(case_ids),
        "review_artifact_url": artifact_url,
        "github_run_url": run_url,
        "chatgpt_url": CHATGPT_URL,
        "body_text": (
            f"LivingEvidenceMap human review required.\n\n"
            f"Pending cases: {pending_count}\n"
            f"Queue fingerprint: {fingerprint}\n\n"
            + (f"Download review package: {artifact_url}\n" if artifact_url else "")
            + (f"GitHub Actions run: {run_url}\n" if run_url else "")
            + f"ChatGPT: {CHATGPT_URL}\n\n"
            "Download and unzip the review package, then open review_package/index.html. "
            "For each unresolved case, use Copy case prompt and Open ChatGPT. "
            "Review cases one-by-one using the stable review_case_id."
        ),
        "send_policy": {
            "send_only_if_pending_count_gt_zero": True,
            "deduplicate_on_queue_fingerprint": True,
        },
    }
    Path(output_path).parent.mkdir(parents=True, exist_ok=True)
    Path(output_path).write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--manifest", required=True)
    p.add_argument("--output", required=True)
    p.add_argument("--repository", default=os.getenv("GITHUB_REPOSITORY", ""))
    p.add_argument("--run-id", default=os.getenv("GITHUB_RUN_ID", ""))
    p.add_argument("--recipient", default=DEFAULT_RECIPIENT)
    p.add_argument("--artifact-url", default=os.getenv("REVIEW_ARTIFACT_URL", ""))
    a = p.parse_args()
    run(a.manifest, a.output, a.repository, a.run_id, a.recipient, a.artifact_url or None)
