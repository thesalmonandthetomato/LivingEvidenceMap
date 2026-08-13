# API adjudication of residual duplicate candidates.
# Uses OPENAI_API_KEY from the GitHub Actions environment.

library(httr2)
library(jsonlite)
library(dplyr)
library(readr)
library(tibble)

adjudicate_duplicate <- function(
  incoming,
  historical,
  model = Sys.getenv("OPENAI_DUPLICATE_MODEL", "gpt-5-mini")
) {
  prompt <- paste0(
    "You are adjudicating whether two bibliographic records represent the same publication.\n",
    "Return JSON only with keys: decision, confidence, rationale.\n",
    "decision must be exactly one of duplicate, not_duplicate, uncertain.\n",
    "Use bibliographic evidence only; do not infer duplication from topical similarity alone.\n\n",
    "INCOMING RECORD:\n",
    paste(names(incoming), incoming, sep = ": ", collapse = "\n"),
    "\n\nHISTORICAL RECORD:\n",
    paste(names(historical), historical, sep = ": ", collapse = "\n")
  )

  body <- list(
    model = model,
    store = FALSE,
    reasoning = list(effort = "low"),
    input = list(
      list(
        role = "user",
        content = list(
          list(
            type = "input_text",
            text = prompt
          )
        )
      )
    ),
    text = list(
      verbosity = "low",
      format = list(
        type = "json_schema",
        name = "duplicate_adjudication",
        strict = TRUE,
        schema = list(
          type = "object",
          additionalProperties = FALSE,
          properties = list(
            decision = list(
              type = "string",
              enum = list(
                "duplicate",
                "not_duplicate",
                "uncertain"
              )
            ),
            confidence = list(
              type = "number",
              minimum = 0,
              maximum = 1
            ),
            rationale = list(
              type = "string"
            )
          ),
          required = c(
            "decision",
            "confidence",
            "rationale"
          )
        )
      )
    )
  )

  response <- request("https://api.openai.com/v1/responses") |>
    req_auth_bearer_token(Sys.getenv("OPENAI_API_KEY")) |>
    req_body_json(body, auto_unbox = TRUE) |>
    req_timeout(120) |>
    req_retry(max_tries = 3, backoff = ~ 2^.x) |>
    req_perform() |>
    resp_body_json()

  # Extract the first message output containing output_text.
  message_items <- Filter(
    function(x) {
      is.list(x) &&
        identical(x$type, "message")
    },
    response$output
  )

  if (!length(message_items)) {
    stop("No message output returned by Responses API")
  }

  text_items <- unlist(
    lapply(
      message_items,
      function(x) {
        Filter(
          function(y) {
            is.list(y) &&
              identical(y$type, "output_text") &&
              !is.null(y$text)
          },
          x$content
        )
      }
    ),
    recursive = FALSE
  )

  if (!length(text_items)) {
    stop("No output_text returned by Responses API")
  }

  raw_text <- text_items[[1]]$text

  if (
    is.null(raw_text) ||
    !is.character(raw_text) ||
    length(raw_text) != 1L ||
    !nzchar(raw_text)
  ) {
    stop("Responses API returned empty output_text")
  }

  # Parse without vector simplification.
  parsed <- jsonlite::fromJSON(
    raw_text,
    simplifyVector = FALSE
  )

  if (!is.list(parsed)) {
    stop("Duplicate adjudication response is not a JSON object")
  }

  required <- c(
    "decision",
    "confidence",
    "rationale"
  )

  if (!all(required %in% names(parsed))) {
    stop(
      paste0(
        "Duplicate adjudication missing required keys. Returned: ",
        paste(names(parsed), collapse = ", ")
      )
    )
  }

  # Extract the three fields directly by name.
  decision_value <- parsed[["decision"]]
  confidence_value <- parsed[["confidence"]]
  rationale_value <- parsed[["rationale"]]

  # Each field must be a scalar.
  if (
    !is.character(decision_value) ||
    length(decision_value) != 1L
  ) {
    stop("Invalid duplicate adjudication decision")
  }

  if (
    !decision_value %in%
      c("duplicate", "not_duplicate", "uncertain")
  ) {
    stop(
      paste0(
        "Invalid duplicate adjudication decision: ",
        decision_value
      )
    )
  }

  confidence_value <- suppressWarnings(
    as.numeric(confidence_value)
  )

  if (
    length(confidence_value) != 1L ||
    is.na(confidence_value) ||
    confidence_value < 0 ||
    confidence_value > 1
  ) {
    stop("Invalid duplicate adjudication confidence")
  }

  if (
    !is.character(rationale_value) ||
    length(rationale_value) != 1L ||
    is.na(rationale_value) ||
    !nzchar(rationale_value)
  ) {
    stop("Duplicate adjudication rationale is empty")
  }

  # Deliberately return a simple named atomic vector.
  # The caller must not use $ or named [[...]] access.
  result <- c(
    decision_value,
    as.character(confidence_value),
    rationale_value
  )

  names(result) <- c(
    "decision",
    "confidence",
    "rationale"
  )

  result
}


run_duplicate_adjudication <- function(
  candidate_file,
  incoming_file,
  historical_file,
  output_file
) {
  candidates <- read_csv(
    candidate_file,
    show_col_types = FALSE
  )

  incoming <- read_corpus(incoming_file)

  historical <- read_csv(
    historical_file,
    show_col_types = FALSE
  )

  if (!"incoming_row" %in% names(candidates)) {
    stop("Candidate file lacks incoming_row")
  }

  results <- lapply(
    seq_len(nrow(candidates)),
    function(i) {
      candidate <- candidates[i, ]

      inc <- incoming[
        candidate$incoming_row,
        ,
        drop = FALSE
      ]

      hist <- historical[
        historical$record_id ==
          candidate$matched_master_record_id,
        ,
        drop = FALSE
      ]

      if (nrow(hist) != 1) {
        stop(
          paste0(
            "Historical match not found uniquely for ",
            candidate$matched_master_record_id
          )
        )
      }

      adjudication <- adjudicate_duplicate(
        inc,
        hist
      )

      # Hard assertion: the API adapter must return exactly
      # three scalar values.
      if (
        !is.atomic(adjudication) ||
        length(adjudication) != 3L
      ) {
        stop(
          "Adjudicator returned unexpected result structure"
        )
      }

      tibble(
        incoming_row = candidate$incoming_row,
        matched_master_record_id =
          candidate$matched_master_record_id,
        duplicate_basis = candidate$duplicate_basis,
        title_similarity = candidate$title_similarity,

        # Positional access only.
        decision = adjudication[[1L]],
        confidence = suppressWarnings(
          as.numeric(adjudication[[2L]])
        ),
        rationale = adjudication[[3L]]
      )
    }
  ) |>
    bind_rows()

  if (nrow(results) != nrow(candidates)) {
    stop(
      paste0(
        "Expected ",
        nrow(candidates),
        " adjudications but produced ",
        nrow(results)
      )
    )
  }

  write_csv(
    results,
    output_file
  )

  results
}
