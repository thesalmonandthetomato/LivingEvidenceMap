# API adjudication of residual duplicate candidates.
# Uses OPENAI_API_KEY from the GitHub Actions environment.

library(httr2)
library(jsonlite)
library(dplyr)
library(readr)
library(tibble)

adjudicate_duplicate <- function(incoming, historical, model = Sys.getenv("OPENAI_DUPLICATE_MODEL", "gpt-5-mini")) {
  prompt <- paste0(
    "You are adjudicating whether two bibliographic records represent the same publication.\n",
    "Return JSON only with keys: decision, confidence, rationale.\n",
    "decision must be exactly one of duplicate, not_duplicate, uncertain.\n",
    "Use bibliographic evidence only; do not infer duplication from topical similarity alone.\n\n",
    "INCOMING RECORD:\n", paste(names(incoming), incoming, sep = ": ", collapse = "\n"),
    "\n\nHISTORICAL RECORD:\n", paste(names(historical), historical, sep = ": ", collapse = "\n")
  )
  body <- list(
    model = model, store = FALSE, reasoning = list(effort = "low"),
    input = list(list(role = "user", content = list(list(type = "input_text", text = prompt)))),
    text = list(verbosity = "low", format = list(
      type = "json_schema", name = "duplicate_adjudication", strict = TRUE,
      schema = list(type = "object", additionalProperties = FALSE,
        properties = list(
          decision = list(type = "string", enum = list("duplicate", "not_duplicate", "uncertain")),
          confidence = list(type = "number", minimum = 0, maximum = 1),
          rationale = list(type = "string")
        ), required = c("decision", "confidence", "rationale"))))
  )
  response <- request("https://api.openai.com/v1/responses") |>
    req_auth_bearer_token(Sys.getenv("OPENAI_API_KEY")) |>
    req_body_json(body, auto_unbox = TRUE) |>
    req_timeout(120) |>
    req_retry(max_tries = 3, backoff = ~ 2^.x) |>
    req_perform() |>
    resp_body_json()
  message_items <- response$output[vapply(response$output, function(x) identical(x$type, "message"), logical(1))]
  content_items <- unlist(lapply(message_items, function(x) x$content), recursive = FALSE)
  text_items <- content_items[vapply(content_items, function(x) identical(x$type, "output_text") && !is.null(x$text), logical(1))]
  if (!length(text_items)) stop("No output_text returned")
  parsed <- fromJSON(text_items[[1]]$text, simplifyVector = TRUE)
  tibble(decision = parsed$decision, confidence = as.numeric(parsed$confidence), rationale = parsed$rationale)
}

run_duplicate_adjudication <- function(candidate_file, incoming_file, historical_file, output_file) {
  candidates <- read_csv(candidate_file, show_col_types = FALSE)
  incoming <- read_corpus(incoming_file)
  historical <- read_csv(historical_file, show_col_types = FALSE)
  if (!"incoming_row" %in% names(candidates)) stop("Candidate file lacks incoming_row")
  results <- lapply(seq_len(nrow(candidates)), function(i) {
    c <- candidates[i, ]
    inc <- incoming[c$incoming_row, , drop = FALSE]
    hist <- historical[historical$record_id == c$matched_master_record_id, , drop = FALSE]
    if (nrow(hist) != 1) stop("Historical match not found uniquely")
    decision <- adjudicate_duplicate(inc, hist)
    tibble(incoming_row = c$incoming_row,
      matched_master_record_id = c$matched_master_record_id,
      duplicate_basis = c$duplicate_basis,
      title_similarity = c$title_similarity,
      decision = decision$decision,
      confidence = decision$confidence,
      rationale = decision$rationale)
  }) |> bind_rows()
  write_csv(results, output_file)
  results
}
