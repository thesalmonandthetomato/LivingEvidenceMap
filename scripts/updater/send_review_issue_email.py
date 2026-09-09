#!/usr/bin/env python3
"""Send a human-review notification email for the weekly updater.

SMTP credentials are read from environment variables. REVIEW_EMAIL is optional;
when absent, the SMTP username is used as the recipient. No credentials are
printed or written to artefacts.
"""

import argparse
import os
import smtplib
import ssl
from email.message import EmailMessage


def require_env(name: str) -> str:
    value = os.getenv(name, "").strip()
    if not value:
        raise RuntimeError(f"Required environment variable {name} is not set")
    return value


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--issue-url", required=True)
    parser.add_argument("--review-count", required=True, type=int)
    parser.add_argument("--review-date", required=True)
    parser.add_argument("--workflow-url", required=True)
    args = parser.parse_args()

    smtp_username = require_env("SMTP_USERNAME")
    smtp_password = require_env("SMTP_PASSWORD")
    smtp_host = require_env("SMTP_HOST")
    smtp_port = int(require_env("SMTP_PORT"))
    recipient = os.getenv("REVIEW_EMAIL", "").strip() or smtp_username

    msg = EmailMessage()
    msg["Subject"] = f"Living Evidence Map: human review required — {args.review_date}"
    msg["From"] = smtp_username
    msg["To"] = recipient
    msg.set_content(
        "The weekly Living Evidence Map update completed automated processing "
        "but requires human adjudication before the master can be promoted.\n\n"
        f"Review items: {args.review_count}\n"
        "Master: unchanged\n"
        "Lens checkpoint: unchanged until review is resolved\n\n"
        f"Open the GitHub review issue:\n{args.issue_url}\n\n"
        "Bring that issue into ChatGPT to adjudicate the outstanding records.\n\n"
        f"Workflow run:\n{args.workflow_url}\n"
    )

    context = ssl.create_default_context()
    if smtp_port == 465:
        with smtplib.SMTP_SSL(smtp_host, smtp_port, context=context) as server:
            server.login(smtp_username, smtp_password)
            server.send_message(msg)
    else:
        with smtplib.SMTP(smtp_host, smtp_port) as server:
            server.ehlo()
            server.starttls(context=context)
            server.ehlo()
            server.login(smtp_username, smtp_password)
            server.send_message(msg)

    print(f"Human-review email sent for {args.review_count} review item(s).")


if __name__ == "__main__":
    main()
