#!/usr/bin/env bash
# Only called after the final W08 marker and registry are committed.
set -euo pipefail
RELEASE="$1"
STATE="$2"
BRANCH=workflow01-final-architecture
# Reconcile with the latest committed state; never use stale status after a retry.
git fetch origin "$BRANCH"
git show "origin/$BRANCH:docs/current_run/current_run_status.json" > "$RUNNER_TEMP/w09-current-status.json"
git show "origin/$BRANCH:$STATE" > "$RUNNER_TEMP/w09-routing-marker.json"
git show "origin/$BRANCH:docs/workflow08b/monthly_checkpoint_registry.json" > "$RUNNER_TEMP/w09-registry.json"
gh run list --repo "$GITHUB_REPOSITORY" --workflow report_workflow09_figures.yml \
  --branch "$BRANCH" --event workflow_dispatch --limit 100 \
  --json displayTitle,status,conclusion,databaseId > "$RUNNER_TEMP/w09-runs.json"
Rscript scripts/workflow08b/ensure_w09_handoff.R \
  "$RUNNER_TEMP/w09-current-status.json" "$RELEASE" "$RUNNER_TEMP/w09-routing-marker.json" \
  "$RUNNER_TEMP/w09-registry.json" "$RUNNER_TEMP/w09-runs.json" "$RUNNER_TEMP/w09-action.json"
case "$(jq -r .action "$RUNNER_TEMP/w09-action.json")" in
  complete) echo "PASS: W09 already completed for accepted release";;
  await) echo "PASS: matching W09 execution already active";;
  dispatch)
    gh workflow run report_workflow09_figures.yml --repo "$GITHUB_REPOSITORY" --ref "$BRANCH" \
      -f expected_update_id="$(jq -r .update_id "$RELEASE")" \
      -f expected_w08_run_id="$(jq -r .w08_run_id "$RELEASE")" \
      -f expected_w08_sha256="$(jq -r .w08_canonical_sha256 "$RELEASE")"
    echo "PASS: W09 dispatched for exact accepted release";;
  *) exit 1;;
esac
