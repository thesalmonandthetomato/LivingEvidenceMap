#!/usr/bin/env python3
"""Offline scheduler regression tests. Never contacts GitHub or dispatches W00."""
from pathlib import Path
import os
import subprocess
import tempfile
import textwrap

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / ".github/workflows/schedule_production_w00_monthly.yml"

def get_script():
    lines = SOURCE.read_text().splitlines()
    marker = "        run: |"
    assert lines.count(marker) == 1, "Expected exactly one scheduler shell block"
    start = lines.index(marker) + 1
    body = []
    for line in lines[start:]:
        if line.strip() and not line.startswith("          "):
            break
        body.append(line[10:] if line.startswith("          ") else "")
    script = "\n".join(body) + "\n"
    subprocess.run(["bash", "-n"], input=script, text=True, check=True)
    return script

def case(script, local_date, schedule, existing=False, should_dispatch=False):
    with tempfile.TemporaryDirectory() as temporary:
        tmp = Path(temporary)
        bin_dir = tmp / "bin"
        bin_dir.mkdir()
        fake_date = bin_dir / "date"
        fake_date.write_text(textwrap.dedent("""\
            #!/usr/bin/env bash
            case "$*" in
              *'+%Y-%m-%dT%H:%M:%SZ'*) echo '2026-11-19T00:00:00Z' ;;
              *'+%Y-%m-%d'*) echo "$FAKE_LOCAL_DATE" ;;
              *'+%Y-%m'*) echo "${FAKE_LOCAL_DATE:0:7}" ;;
              *'+%d'*) echo "${FAKE_LOCAL_DATE:8:2}" ;;
              *'+%s'*) echo '1795046400' ;;
              *) echo "Unexpected date invocation: $*" >&2; exit 3 ;;
            esac
        """))
        fake_gh = bin_dir / "gh"
        fake_gh.write_text(textwrap.dedent("""\
            #!/usr/bin/env bash
            if [[ "$1" != "api" ]]; then exit 4; fi
            if [[ "${2:-}" == "--method" ]]; then
              printf 'POST\n' >> "$GH_TEST_CALLS"
              exit 0
            fi
            cat "$GH_TEST_RESPONSE"
        """))
        fake_date.chmod(0o755)
        fake_gh.chmod(0o755)
        response = tmp / "response.json"
        response.write_text('{"workflow_runs":[{"created_at":"2026-11-19T15:00:00Z"}]}'
                            if existing else '{"workflow_runs":[]}')
        calls = tmp / "calls.txt"
        summary = tmp / "summary.md"
        env = {**os.environ,
            "PATH": str(bin_dir) + os.pathsep + os.environ["PATH"],
            "GH_REPO": "thesalmonandthetomato/LivingEvidenceMap",
            "GH_TEST_RESPONSE": str(response),
            "GH_TEST_CALLS": str(calls),
            "GITHUB_STEP_SUMMARY": str(summary),
            "EVENT_NAME": "schedule",
            "SCHEDULE": schedule,
            "FAKE_LOCAL_DATE": local_date,
        }
        result = subprocess.run(["bash", "-c", script], text=True,
                                capture_output=True, env=env)
        assert result.returncode == 0, (result.stdout, result.stderr)
        actual = calls.read_text().count("POST") if calls.exists() else 0
        assert actual == int(should_dispatch), (
            f"{local_date}, {schedule}: expected {should_dispatch}, got {actual}; "
            + result.stdout + result.stderr
        )

def main():
    script = get_script()
    normal = "0 9,15,21 19 * *"
    catchup = "0 14,17,20 20 11 *"
    case(script, "2026-12-19", normal, should_dispatch=True)
    case(script, "2026-12-19", normal, existing=True)
    case(script, "2026-12-20", normal)
    case(script, "2026-11-20", catchup, should_dispatch=True)
    case(script, "2026-11-20", catchup, existing=True)
    case(script, "2027-11-20", catchup)
    print("PASS: monthly 24-hour window, one-off 14:00 catch-up, duplicate prevention, Bash syntax")

if __name__ == "__main__":
    main()
