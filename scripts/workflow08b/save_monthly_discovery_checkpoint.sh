#!/usr/bin/env bash
set -euo pipefail
ROOT="$1"; RUN="$2"; RECEIPT="$3"; FINAL="${4:-false}"
: "${W08B_DRAFT_POINTER:?monthly draft pointer not configured}"
export W08B_MONTHLY_DRAFT=1
export W08B_FINAL_PUBLISH=0
commit_pointer(){
  git config user.name 'github-actions[bot]'
  git config user.email '41898282+github-actions[bot]@users.noreply.github.com'
  git add "$W08B_DRAFT_POINTER"
  if ! git diff --cached --quiet; then
    git commit -m "W08b: record verified monthly draft checkpoint [skip ci]"
    git pull --rebase origin workflow01-final-architecture
    git push origin HEAD:workflow01-final-architecture
  fi
}
Rscript scripts/workflow08b/archive_discovery.R "$ROOT" "$RUN" "$RECEIPT"
commit_pointer
if [ "$FINAL" = true ]; then
  Rscript scripts/workflow08b/publish_monthly_discovery_draft.R \
    "$W08B_DRAFT_POINTER" "$ROOT/monthly_discovery_status.json" "$RECEIPT"
  commit_pointer
fi
