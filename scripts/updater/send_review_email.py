#!/usr/bin/env python3
"""Send a LivingEvidenceMap human-review notification via SMTP.

Reads a pre-built notification payload JSON and SMTP credentials from environment.
No credentials are written to stdout or artefacts.
"""
import argparse
import json
import os
import smtplib
import ssl
from email.message import EmailMessage
from pathlib import Path


def require_env(name):
    value = os.getenv(name)
    if not value:
        raise SystemExit(f"Missing required environment variable: {name}")
    return value


def send(payload_path):
    payload = json.loads(Path(payload_path).read_text(encoding="utf-8"))
    if int(payload.get("pending_count") or 0) <= 0:
        print("No pending review cases; email not sent.")
        return

    host = require_env("SMTP_HOST")
    port = int(require_env("SMTP_PORT"))
    username = require_env("SMTP_USERNAME")
    password = require_env("SMTP_PASSWORD")
    recipient = payload.get("recipient")
    if not recipient:
        raise SystemExit("Notification payload has no recipient")

    msg = EmailMessage()
    msg["From"] = username
    msg["To"] = recipient
    msg["Subject"] = payload.get("subject") or "LivingEvidenceMap human review required"
    msg.set_content(payload.get("body_text") or "LivingEvidenceMap human review required.")

    context = ssl.create_default_context()
    if port == 465:
        with smtplib.SMTP_SSL(host, port, context=context, timeout=30) as smtp:
            smtp.login(username, password)
            smtp.send_message(msg)
    else:
        with smtplib.SMTP(host, port, timeout=30) as smtp:
            smtp.ehlo()
            smtp.starttls(context=context)
            smtp.ehlo()
            smtp.login(username, password)
            smtp.send_message(msg)

    print(f"Review notification sent to {recipient} for {payload['pending_count']} pending case(s).")


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--payload", required=True)
    a = p.parse_args()
    send(a.payload)
