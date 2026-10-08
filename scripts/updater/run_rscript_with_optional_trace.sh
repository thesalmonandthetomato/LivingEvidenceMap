#!/usr/bin/env bash
# Optional tracing wrapper for existing Rscript workflow steps.
set -euo pipefail
if [[ "${DEPENDENCY_TRACE:-false}" != "true" ]]; then
  exec Rscript "$@"
fi
if ! command -v strace >/dev/null 2>&1; then
  echo "Dependency tracing requested, but strace is unavailable" >&2
  exit 2
fi
if [[ $# -lt 1 ]]; then
  echo "Specify an R script and its arguments" >&2
  exit 2
fi
trace_dir="${DEPENDENCY_TRACE_DIR:-outputs/dependency_trace}"
mkdir -p "$trace_dir"
script_label="$(basename "$1" | tr -c '[:alnum:]_.-' '_')"
Rscript scripts/updater/trace_file_access.R "$trace_dir/$script_label" -- Rscript "$@"
