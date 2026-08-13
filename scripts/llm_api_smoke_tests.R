# One-record API smoke tests. These are deliberately separate from production runs.
# Requires OPENAI_API_KEY in the environment. Never write the key to the repo.

source("R/llm_screening.R")
source("R/llm_adjudication.R")

stopifnot(nzchar(Sys.getenv("OPENAI_API_KEY")))

call_responses_api <- function(body) {
  httr2::request("https://api.openai.com/v1/responses") |>
    httr2::req_auth_bearer_token(Sys.getenv("OPENAI_API_KEY")) |>
    httr2::req_body_json(body, auto_unbox = TRUE) |>
    httr2::req_timeout(120) |>
    httr2::req_retry(max_tries = 3, backoff = ~ 2^.x) |>
    httr2::req_perform() |>
    httr2::resp_body_json()
}

extract_output_text <- function(response) {
  message_items <- response$output[vapply(response$output, function(item) identical(item$type, "message"), logical(1))]
  content_items <- unlist(lapply(message_items, function(item) item$content), recursive = FALSE)
  text_items <- content_items[vapply(content_items, function(item) identical(item$type, "output_text") && !is.null(item$text), logical(1))]
  if (!length(text_items)) stop("No output_text returned")
  text_items[[1]]$text
}

# 1. Screening: exactly one record using the established production prompt/schema.
screen_body <- list(
  model = "gpt-5-mini", store = FALSE, reasoning = list(effort = "low"),
  input = list(
    list(role = "system", content = list(list(type = "input_text", text = salmon_llm_system_prompt()))),
    list(role = "user", content = list(list(type = "input_text", text = paste0(
      "TITLE\nSalmon farming production and environmental interactions\n\n",
      "ABSTRACT\nA study of environmental effects associated with farmed salmon production.\n\n",
      "Decide whether this record meets the salmon-farming eligibility criteria."
    ))))
  ),
  text = list(verbosity = "low", format = list(
    type = "json_schema", name = "salmon_farming_relevance_screen", strict = TRUE,
    schema = salmon_llm_response_schema()
  ))
)
screen_answer <- jsonlite::fromJSON(extract_output_text(call_responses_api(screen_body)))
stopifnot(screen_answer$decision %in% c("retain", "exclude", "uncertain"), nzchar(screen_answer$reason))

# 2. Species/geography adjudication: exactly one representative flagged record.
adj_row <- tibble::tibble(
  record_id = "SMOKE-ADJ-1", title = "Salmon aquaculture in Norway",
  abstract = "The study examines salmon farming in Norway and reports production impacts.",
  species_review_required = TRUE, deterministic_species = "Atlantic salmon",
  deterministic_species_ids = "SALMO_SALAR", species_reasons = "Title/abstract species evidence",
  non_target_species = "", geography_review_required = TRUE,
  geography_review_reason = "Representative geography review",
  deterministic_primary_countries = "Norway", deterministic_primary_iso3c = "NOR",
  geography_candidates = "Norway [NOR]; tier 1"
)
adj_body <- list(
  model = "gpt-5-mini", store = FALSE, reasoning = list(effort = "low"),
  input = list(
    list(role = "system", content = list(list(type = "input_text", text = annotation_adjudication_system_prompt()))),
    list(role = "user", content = list(list(type = "input_text", text = make_annotation_adjudication_prompt(adj_row))))
  ),
  text = list(verbosity = "low", format = list(
    type = "json_schema", name = "annotation_adjudication", strict = TRUE,
    schema = annotation_adjudication_schema()
  ))
)
adj_answer <- jsonlite::fromJSON(extract_output_text(call_responses_api(adj_body)))
stopifnot(adj_answer$species_decision %in% c("ACCEPT", "CHANGE", "UNRESOLVED", "NOT_REVIEWED"))
stopifnot(adj_answer$geography_decision %in% c("ACCEPT", "CHANGE", "UNRESOLVED", "NOT_REVIEWED"))

# 3. Topics: exactly one API call against a deliberately tiny ontology.
# This tests topic API/schema integration without running the expensive full classifier.
topic_paths <- c(
  "Production > Farming systems > Production performance > Growth",
  "Environment > Environmental impacts > Water quality > Nutrients"
)
topic_prompt <- paste(
  "You are classifying a scientific abstract for a salmon-farming evidence map.",
  "Select every listed four-level path that represents a substantive research objective,",
  "intervention, exposure, outcome, interpretation or application. Use only listed paths.",
  "Return an empty assignments array if neither applies.", sep = "\n"
)
topic_body <- list(
  model = "gpt-5-mini", store = FALSE, reasoning = list(effort = "low"),
  input = list(
    list(role = "system", content = list(list(type = "input_text", text = topic_prompt))),
    list(role = "user", content = list(list(type = "input_text", text = paste0(
      "VALID PATHS\n", paste(topic_paths, collapse = "\n"),
      "\n\nTITLE\nSalmon farming growth performance and nutrient discharge",
      "\n\nABSTRACT\nThe study measures growth performance in farmed salmon and nutrient concentrations in receiving water."
    ))))
  ),
  text = list(verbosity = "low", format = list(
    type = "json_schema", name = "topic_smoke", strict = TRUE,
    schema = list(
      type = "object", properties = list(
        assignments = list(type = "array", items = list(type = "string", enum = topic_paths)),
        review_required = list(type = "boolean"), review_reason = list(type = c("string", "null"))
      ), required = c("assignments", "review_required", "review_reason"), additionalProperties = FALSE
    )
  ))
)
topic_answer <- jsonlite::fromJSON(extract_output_text(call_responses_api(topic_body)))
stopifnot(all(topic_answer$assignments %in% topic_paths), is.logical(topic_answer$review_required))

cat("LLM smoke tests passed: 1 screening call, 1 adjudication call, 1 topic call.\n")
