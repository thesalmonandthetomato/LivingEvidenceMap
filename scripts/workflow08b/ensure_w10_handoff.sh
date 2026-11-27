#!/usr/bin/env bash
set -euo pipefail
BRANCH=workflow01-final-architecture
git fetch origin "$BRANCH"
D="$(mktemp -d "$RUNNER_TEMP/w10-handoff.XXXXXX")"
trap 'rm -rf "$D"' EXIT
git show "origin/$BRANCH:docs/current_run/current_run_status.json" > "$D/status.json"
UPDATE="$(jq -er .update_id "$D/status.json")"
RUN="$(jq -er '.workflow_runs.W08|tostring' "$D/status.json")"
[[ "$UPDATE" =~ ^[A-Za-z0-9._-]+$ && "$RUN" =~ ^[0-9]+$ ]]
git show "origin/$BRANCH:docs/workflow08/zenodo/run-$RUN.json" > "$D/pointer.json"
git show "origin/$BRANCH:docs/reporting/workflow_09/data/workflow_inputs/w08_summary.json" > "$D/summary.json"
SHA="$(jq -er .final_canonical_jsonl_sha256 "$D/pointer.json")"
if [[ $# -eq 3 ]]; then
  test "$UPDATE" = "$1"
  test "$RUN" = "$2"
  test "$SHA" = "$3"
else
  test "$#" -eq 0
fi
jq -n --arg u "$UPDATE" --arg r "$RUN" --arg h "$SHA" '{update_id:$u,w08_run_id:$r,w08_canonical_sha256:$h}' > "$D/release.json"
gh run list --repo "$GITHUB_REPOSITORY" --workflow workflow_10_dashboard.yml \
  --branch "$BRANCH" --event workflow_dispatch --limit 100 \
  --json displayTitle,status,conclusion,databaseId > "$D/runs.json"
Rscript scripts/workflow08b/ensure_w10_handoff.R "$D/status.json" "$D/release.json" "$D/pointer.json" "$D/summary.json" "$D/runs.json" "$D/action.json"
case "$(jq -er .action "$D/action.json")" in
  complete) echo "PASS: W10 already complete";;
  await) echo "PASS: matching W10 execution active";;
  dispatch)
    gh workflow run workflow_10_dashboard.yml --repo "$GITHUB_REPOSITORY" --ref "$BRANCH" \
      -f expected_update_id="$UPDATE" -f expected_w08_run_id="$RUN" -f expected_w08_sha256="$SHA"
    echo "PASS: exact-release W10 dispatched";;
  *) exit 1;;
esac
