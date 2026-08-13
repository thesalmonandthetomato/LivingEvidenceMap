# Shared setup for executable pipeline scripts.

project_root <- here::here()

ensure_relevance_packages <- function() {
  required <- c("dplyr", "fs", "glmnet", "here", "Matrix", "purrr",
                "quanteda", "readr", "stringdist", "stringi", "stringr",
                "tibble", "tidyr", "yaml")
  missing <- required[!vapply(required, requireNamespace, logical(1), quietly = TRUE)]
  if (length(missing)) {
    stop("Required R packages are missing: ", paste(missing, collapse = ", "), call. = FALSE)
  }
  invisible(TRUE)
}
