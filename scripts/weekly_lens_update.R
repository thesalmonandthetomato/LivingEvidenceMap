# One-command orchestration for the recurring Lens update.
# The harvest step is deliberately separate from this R pipeline because the
# Lens API response is JSON, while the established update pipeline accepts RIS.
# This script expects a normalised RIS input placed in the dated update folder.

source("scripts/run_lens_update.R")
