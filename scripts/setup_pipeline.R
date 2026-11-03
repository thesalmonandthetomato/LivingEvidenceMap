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

# Extract text returned by the OpenAI Responses API. The API returns text
# inside output message content blocks; some clients may also expose a
# top-level output_text convenience field. Fail explicitly if neither form is
# present so technical API failures cannot be mistaken for substantive review
# uncertainty.
extract_openai_output_text <- function(response) {
  if (!is.null(response$output_text)) {
    text <- paste(as.character(response$output_text), collapse = "\n")
    if (nzchar(trimws(text))) return(text)
  }

  output <- response$output
  if (is.null(output) || !length(output)) {
    stop("OpenAI Responses API response contained no output.", call. = FALSE)
  }

  texts <- character()
  for (item in output) {
    content <- item$content
    if (is.null(content) || !length(content)) next
    for (part in content) {
      if (!is.null(part$text)) {
        text <- as.character(part$text)
        if (length(text) && nzchar(trimws(text[[1L]]))) texts <- c(texts, text[[1L]])
      }
    }
  }

  if (!length(texts)) {
    stop("OpenAI Responses API response contained no output text.", call. = FALSE)
  }
  paste(texts, collapse = "\n")
}
