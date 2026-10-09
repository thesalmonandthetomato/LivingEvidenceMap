# =============================================================================
# File: scripts/setup_pipeline.R
# Purpose: Shared package and project setup for pipeline scripts.
# =============================================================================

required_packages <- c(
  "digest", "dplyr", "fs", "glmnet", "here", "Matrix", "purrr", "quanteda",
  "readr", "stringdist", "stringi", "stringr", "tibble", "tidyr", "yaml"
)

missing <- required_packages[!vapply(required_packages, requireNamespace, logical(1), quietly = TRUE)]
if (length(missing)) {
  stop("Missing required R packages: ", paste(missing, collapse = ", "), call. = FALSE)
}

invisible(lapply(required_packages, library, character.only = TRUE))

ensure_relevance_packages <- function() {
  invisible(NULL)
}
