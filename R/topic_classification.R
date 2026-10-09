# Topic hierarchy classifier for the salmon scoping-review evidence map.
# Ported into this repository so topic classification has no runtime dependency
# on the historical repository. Full topic classification remains the final
# production stage; the current Lens refresh uses only a one-record smoke test.

classify_topic_hierarchy_single_call <- function(title, abstract, ontology,
                                                  model = "gpt-5-mini") {
  api_key <- Sys.getenv("OPENAI_API_KEY")
  if (!nzchar(api_key)) stop("OPENAI_API_KEY not found.")

  required_columns <- c("broad_topic", "subtopic", "feature", "component", "supporting_terms")
  missing_columns <- setdiff(required_columns, names(ontology))
  if (length(missing_columns) > 0L) {
    stop("Ontology is missing required columns: ", paste(missing_columns, collapse = ", "))
  }

  shorten_terms <- function(x, maximum_terms = 10L) {
    terms <- stringr::str_split(dplyr::coalesce(x, ""), ";\\s*")[[1]]
    terms <- terms[nzchar(terms)]
    terms <- terms[!duplicated(stringr::str_to_lower(terms))]
    paste(utils::head(terms, maximum_terms), collapse = "; ")
  }

  candidate_paths <- ontology |>
    dplyr::distinct(broad_topic, subtopic, feature, component, supporting_terms) |>
    dplyr::arrange(broad_topic, subtopic, feature, component) |>
    dplyr::rowwise() |>
    dplyr::mutate(
      representative_terms = shorten_terms(supporting_terms),
      valid_path = paste(broad_topic, subtopic, feature, component, sep = " > "),
      prompt_line = paste0(valid_path, " | Semantic cues: ", representative_terms)
    ) |>
    dplyr::ungroup()

  valid_paths <- candidate_paths$valid_path

  system_prompt <- paste(
    "You are classifying scientific abstracts for a systematic evidence map",
    "of farmed salmon and rainbow trout research.",
    "Select every valid four-level hierarchy path that represents a substantive",
    "objective, intervention, exposure, measured outcome, interpretation or",
    "application of the study.",
    "A path need not be the primary focus to be substantive.",
    "Semantic cues are non-exhaustive and may be stems, abbreviations, examples,",
    "spelling variants or related concepts. Do not require an exact cue match.",
    "Do not assign a path from an isolated word alone.",
    "Do not assign paths mentioned only as background or motivation.",
    "Use only the listed hierarchy paths. Multiple paths are allowed when genuinely applicable.",
    "For pathology studies, consider organism, illness, treatment, prevention and impacts separately",
    "when each is substantively investigated.",
    "When mortality, morbidity, lesions, severity, prevalence, performance loss, disease resolution",
    "or treatment efficacy are measured, consider the relevant Pathology > Impacts path.",
    "Treat substances or interventions intended to stimulate immune function as pathology treatments",
    "when that is their aquaculture role. Treat probiotics, amino acids and functional ingredients",
    "as Feed > Additives when used as dietary interventions.",
    "Treat fillet or sensory quality outcomes as Consumption > Palatability when that path is available.",
    "Within the same broad-topic and subtopic branch, do not select General > General when a more",
    "specific parallel path is selected. Use General > General only when no more specific path fits.",
    "Return an empty assignments array only when no listed path applies.",
    sep = "\n"
  )

  schema <- list(
    type = "object",
    properties = list(
      assignments = list(type = "array", items = list(type = "string", enum = I(valid_paths))),
      review_required = list(type = "boolean"),
      review_reason = list(type = c("string", "null"))
    ),
    required = c("assignments", "review_required", "review_reason"),
    additionalProperties = FALSE
  )

  user_prompt <- paste0(
    "VALID HIERARCHY PATHS\n", paste(candidate_paths$prompt_line, collapse = "\n"),
    "\n\nTITLE\n", title, "\n\nABSTRACT\n", abstract,
    "\n\nSelect every substantively applicable four-level hierarchy path."
  )

  body <- list(
    model = model, store = FALSE,
    input = list(
      list(role = "system", content = list(list(type = "input_text", text = system_prompt))),
      list(role = "user", content = list(list(type = "input_text", text = user_prompt)))
    ),
    text = list(format = list(type = "json_schema", name = "topic_hierarchy_classification",
                              strict = TRUE, schema = schema))
  )

  response <- httr2::request("https://api.openai.com/v1/responses") |>
    httr2::req_auth_bearer_token(api_key) |>
    httr2::req_body_json(body, auto_unbox = TRUE) |>
    httr2::req_timeout(180) |>
    httr2::req_retry(max_tries = 3, backoff = ~ 2^.x) |>
    httr2::req_error(is_error = function(resp) FALSE) |>
    httr2::req_perform()

  status_code <- httr2::resp_status(response)
  if (status_code >= 400L) stop("OpenAI HTTP ", status_code, ": ", httr2::resp_body_string(response))
  response <- httr2::resp_body_json(response)
  if (!identical(response$status, "completed")) stop("OpenAI response did not complete. Status: ", response$status)

  message_items <- response$output[vapply(response$output, function(item) identical(item$type, "message"), logical(1))]
  if (!length(message_items)) stop("OpenAI response contained no message output.")
  content_items <- unlist(lapply(message_items, function(item) item$content), recursive = FALSE)
  text_items <- content_items[vapply(content_items, function(item) identical(item$type, "output_text") && !is.null(item$text), logical(1))]
  if (!length(text_items)) stop("OpenAI response contained no output_text content.")

  parsed <- jsonlite::fromJSON(text_items[[1]]$text)
  invalid_assignments <- setdiff(parsed$assignments, valid_paths)
  if (length(invalid_assignments)) stop("Invalid hierarchy paths returned: ", paste(invalid_assignments, collapse = ", "))

  if (!length(parsed$assignments)) {
    return(tibble::tibble(broad_topic = character(), subtopic = character(), feature = character(),
                          component = character(), review_required = logical(), review_reason = character()))
  }

  assignment_parts <- stringr::str_split_fixed(parsed$assignments, "\\s*>\\s*", 4)
  result <- tibble::tibble(
    broad_topic = assignment_parts[, 1], subtopic = assignment_parts[, 2],
    feature = assignment_parts[, 3], component = assignment_parts[, 4],
    review_required = parsed$review_required,
    review_reason = if (is.null(parsed$review_reason)) NA_character_ else parsed$review_reason
  )

  result |>
    dplyr::group_by(broad_topic, subtopic) |>
    dplyr::filter(!(feature == "General" & component == "General" &
                       any(feature != "General" | component != "General"))) |>
    dplyr::ungroup()
}
