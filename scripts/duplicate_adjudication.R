# API adjudication of residual duplicate candidates.
# Uses OPENAI_API_KEY from the GitHub Actions environment.

library(httr2)
library(jsonlite)
library(dplyr)
library(readr)
library(tibble)

adjudicate_duplicate <- function(incoming, historical, model = Sys.getenv("OPENAI_DUPLICATE_MODEL", "gpt-5.6")) {
  prompt <- paste0(
    "You are adjudicating whether two bibliographic records represent the same publication.\n",
    "Return JSON only with keys: decision, confidence, rationale.\n",
    "decision must be exactly one of duplicate, not_duplicate, uncertain.\n",
    "Use bibliographic evidence only; do not infer duplication from topical similarity alone.\n\n",
    "INCOMING RECORD:\n", paste(names(incoming), incoming, sep = ": ", collapse = "\n"),
    "\n\nHISTORICAL RECORD:\n", paste(names(historical), historical, sep = ": ", collapse = "\n")
  )

  body <- list(
    model = model,
    input = prompt,
    text = list(format = list(type = "json_schema", name = "duplicate_adjudication",
      schema = list(type = "object", additionalProperties = FALSE,
        properties = list(
          decision = list(type = "string", enum = list("duplicate", "not_duplicate", "uncertain")),
          confidence = list(type = "number", minimum = 0, maximum = 1),
          rationale = list(type = "string")
        ), required = list("decision", "confidence", "rationale")
      ), strict = TRUE)))
  )

  response <- request("https://api.openai.com/v1/responses") |>
    req_auth_bearer_token(Sys.getenv("OPENAI_API_KEY")) |>
    req_headers(`Content-Type` = "application/json") |>
    req_body_json(body) |>
    req_perform()

  raw <- resp_body_json(response, simplifyVector = FALSE)
  text <- raw$output[[1]]$content[[1]]$text
  parsed <- fromJSON(text, simplifyVector = TRUE)
  tibble(decision = parsed$decision, confidence = as.numeric(parsed$confidence), rationale = parsed$rationale)
}

run_duplicate_adjudication <- function(candidate_file, records_file, historical_file, output_file) {
  candidates <- read_csv(candidate_file, show_col_types = FALSE)
  incoming <- read_csv(records_file, show_col_types = FALSE)
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
