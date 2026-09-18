# Experimental ranked runner derived from the validated V4 topic classifier.
# Scientific classification logic and ontology presentation are ported from
# nealhaddaway/salmonscopingreview scripts/52_run_topic_v4_full_corpus.R.
# The deliberate model change is from gpt-5-mini to GPT-5.6 Luna.

suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
  library(purrr)
  library(tibble)
  library(jsonlite)
  library(httr2)
})

input_path <- Sys.getenv("TOPIC_INPUT_PATH", "")
ontology_path <- Sys.getenv("TOPIC_ONTOLOGY_PATH", "data/reference/topic_ontology_v3.csv")
out_dir <- Sys.getenv("TOPIC_OUTPUT_DIR", "")
model <- Sys.getenv("TOPIC_MODEL", "gpt-5.6-luna")
reasoning_effort <- Sys.getenv("TOPIC_REASONING_EFFORT", "medium")
general_code_exclusivity <- tolower(Sys.getenv("TOPIC_GENERAL_CODE_EXCLUSIVITY", "false")) %in% c("1", "true", "yes")

if (!nzchar(input_path)) stop("TOPIC_INPUT_PATH is required")
if (!nzchar(out_dir)) stop("TOPIC_OUTPUT_DIR is required")
if (!file.exists(input_path)) stop("Topic input file not found: ", input_path)
if (!file.exists(ontology_path)) stop("Topic ontology file not found: ", ontology_path)

api_key <- Sys.getenv("OPENAI_API_KEY")
if (!nzchar(api_key)) stop("OPENAI_API_KEY not found")

dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
checkpoint_file <- file.path(out_dir, "topic_v4_checkpoint.rds")
record_output_file <- file.path(out_dir, "topic_classification_records.csv")
long_output_file <- file.path(out_dir, "topic_assignments.csv")
failure_file <- file.path(out_dir, "topic_classification_failures.csv")
system_prompt_file <- file.path(out_dir, "topic_v4_system_prompt.txt")
ontology_prompt_file <- file.path(out_dir, "topic_v4_ontology_prompt.txt")
progress_file <- file.path(out_dir, "topic_v4_progress.csv")

records <- readr::read_csv(input_path, show_col_types = FALSE)
ontology <- readr::read_csv(ontology_path, show_col_types = FALSE)

required_record_columns <- c("record_id", "title", "abstract")
missing_record_columns <- setdiff(required_record_columns, names(records))
if (length(missing_record_columns)) {
  stop("Topic input missing columns: ", paste(missing_record_columns, collapse = ", "))
}

records <- records |>
  dplyr::transmute(
    sampling_stratum = if ("queue_type" %in% names(records)) dplyr::coalesce(as.character(queue_type), "topic") else "topic",
    record_sequence = dplyr::row_number(),
    record_id = as.character(record_id),
    title = dplyr::coalesce(as.character(title), ""),
    abstract = dplyr::coalesce(as.character(abstract), "")
  )

if (anyDuplicated(records$record_id) > 0L) stop("Duplicate record_id values found in topic input")

required_ontology <- c(
  "path_id", "hierarchy_path", "definition", "include_when", "exclude_when",
  "required_subject_terms", "required_focus_terms", "alternative_standalone_cues",
  "supporting_terms_from_old_ontology", "prompt_logic_note"
)
missing_ontology <- setdiff(required_ontology, names(ontology))
if (length(missing_ontology)) {
  stop("Ontology missing columns: ", paste(missing_ontology, collapse = ", "))
}
if (anyDuplicated(ontology$path_id) > 0L) stop("Duplicate ontology path_id values found")
if (anyDuplicated(ontology$hierarchy_path) > 0L) stop("Duplicate ontology hierarchy_path values found")

field_line <- function(label, value) {
  value <- dplyr::coalesce(as.character(value), "")
  if (!nzchar(trimws(value))) return(NULL)
  paste0(label, ": ", value)
}

ontology_entries <- purrr::pmap_chr(
  ontology |>
    dplyr::select(
      path_id, hierarchy_path, definition, include_when, exclude_when,
      required_subject_terms, required_focus_terms, alternative_standalone_cues,
      supporting_terms_from_old_ontology, prompt_logic_note
    ),
  function(path_id, hierarchy_path, definition, include_when, exclude_when,
           required_subject_terms, required_focus_terms, alternative_standalone_cues,
           supporting_terms_from_old_ontology, prompt_logic_note) {
    lines <- c(
      paste0(path_id, " | ", hierarchy_path),
      field_line("Definition", definition),
      field_line("Include when", include_when),
      field_line("Exclude when", exclude_when),
      field_line("Subject concept cues", required_subject_terms),
      field_line("Focus concept cues", required_focus_terms),
      field_line("Alternative specific cues", alternative_standalone_cues),
      field_line("Supporting lexical cues", supporting_terms_from_old_ontology),
      field_line("Interpretation note", prompt_logic_note)
    )
    paste(lines[!vapply(lines, is.null, logical(1))], collapse = "\n")
  }
)
ontology_prompt <- paste(ontology_entries, collapse = "\n\n")

# This prompt is intentionally retained verbatim from the validated legacy V4
# full-corpus classifier. Do not simplify it in the weekly updater.
system_prompt <- paste(
  "You are coding titles and abstracts for a systematic map of salmon",
  "aquaculture research using a fixed systems-based ontology.",
  "",
  "OBJECTIVE",
  "Assign an ontology pathway only when it represents a substantive research",
  "question, intervention, outcome or conclusion investigated by the study.",
  "A concept is not substantive merely because it is mentioned, measured,",
  "controlled for, used as background, or discussed in the introduction.",
  "",
  "DECISION PROCESS FOR EVERY PROPOSED CODE",
  "1. Is the concept only background, motivation, context or prior literature?",
  "   If yes, do not code it.",
  "2. Is the concept only a variable measured to evaluate another intervention",
  "   or exposure? If yes, do not code it as a separate topic.",
  "3. Is the concept itself a substantive research question, intervention,",
  "   outcome or conclusion? If yes, code it.",
  "4. Would removing the code materially misrepresent the paper's contribution?",
  "   If no, do not assign it.",
  "",
  "MULTIPLE CODING",
  "5. Code all genuinely substantive concepts, including meaningful secondary",
  "   outcomes, but do not code every measurement.",
  "6. The ontology is not hierarchical for coding purposes. Do not assign a",
  "   broader or related pathway merely because a more specific pathway applies.",
  "7. Each assigned pathway must independently satisfy the substantive-coding",
  "   rules.",
  "",
  "CONTRASTIVE EXAMPLES",
  "8. Feed-additive trial measuring cortisol: code Feed additives. Do not also",
  "   code Stress unless stress is a substantive research question or conclusion.",
  "9. Vaccine trial measuring antibody titres: code disease prevention/treatment.",
  "   Do not also code physiology unless physiological response is substantive.",
  "10. Sea-lice treatment trial measuring growth: code sea-lice control and",
  "    treatment. Do not also code sea-lice impacts unless impacts are a",
  "    substantive objective or conclusion.",
  "11. Benthic chemistry measured only to evaluate fallowing does not by itself",
  "    justify environmental monitoring as a separate topic.",
  "",
  "LEXICAL ANCHORS",
  "12. The ontology provides subject cues, focus cues, alternative specific",
  "    cues and supporting lexical cues.",
  "13. These are semantic guidance, not literal search rules.",
  "14. Where both subject and focus cues are supplied, infer both concepts",
  "    before assigning the pathway. Generic focus words alone are insufficient.",
  "15. Alternative specific cues can identify a pathway without the ordinary",
  "    subject wording when the context clearly establishes the concept.",
  "",
  "BOUNDARIES",
  "16. Cleaner-fish, lumpfish or wrasse studies in salmon farming normally",
  "    concern sea-lice control, even when sea lice are implicit.",
  "17. Distinguish sea-lice epidemiology, control/treatment, fish response",
  "    and impacts by the substantive question.",
  "18. Use Epidemiology when the substantive question concerns occurrence,",
  "    prevalence, incidence, abundance, distribution, transmission, outbreak",
  "    patterns, surveillance or risk factors, even where no intervention is",
  "    studied.",
  "19. Distinguish other-disease epidemiology, diagnosis/detection,",
  "    prevention/treatment and general disease biology.",
  "20. Product safety and health effects of eating salmon belong under Product.",
  "    Public-health effects caused by farming belong under People and society.",
  "21. General or multiple-issue pathways are exceptional. Use them only when",
  "    the paper genuinely investigates multiple issues in that domain or",
  "    provides a broad synthesis. If one or more specific pathways completely",
  "    describe the study, do not additionally assign a General pathway.",
  "22. Methods applies only where methodological development, validation,",
  "    comparison or review is itself a principal contribution.",
  "23. For reviews, code each theme actually synthesised or critically",
  "    evaluated, not topics mentioned only for context.",
  "",
  "OUTPUT",
  "24. Use only supplied path_id values.",
  "25. For each assignment, provide one concise evidence-based reason.",
  "26. Set review_required to true only where the abstract is genuinely",
  "    ambiguous, truncated, insufficient or lacks an appropriate pathway.",
  "",
  "ROLE OF EACH ASSIGNMENT",
  "27. For every assigned pathway, classify its role as PRIMARY or SECONDARY.",
  "28. PRIMARY means removing the pathway would materially change the description of",
  "    the paper's principal research question or main contribution.",
  "29. More than one PRIMARY pathway is allowed when the paper explicitly investigates",
  "    linked co-equal questions or when the main contribution cannot be accurately",
  "    described without both pathways.",
  "30. SECONDARY means the pathway is independently substantive but clearly subordinate",
  "    to the main contribution.",
  "31. Do not use SECONDARY for background concepts, contextual mentions, routine",
  "    endpoints or incidental measurements. Such concepts must remain unassigned.",
  sep = "\n"
)

# Optional versioned rule. It is disabled by default so completed v3.3 runs
# remain reproducible; v3.4 workflows enable it explicitly.
if (general_code_exclusivity) {
  system_prompt <- paste(
    system_prompt,
    "",
    "GENERAL-CODE EXCLUSIVITY",
    "32. A pathway labelled General may be assigned only when no more specific",
    "    pathway under the same immediate parent adequately represents the",
    "    substantive topic.",
    "33. If any more specific sibling pathway is assigned, do not also assign",
    "    the General pathway. General pathways are fallbacks, not additional",
    "    codes for breadth, context, pathology or supporting findings.",
    sep = "\n"
  )
}

readr::write_lines(system_prompt, system_prompt_file)
readr::write_lines(ontology_prompt, ontology_prompt_file)

response_schema <- list(
  type = "object",
  properties = list(
    assignments = list(
      type = "array",
      items = list(
        type = "object",
        properties = list(
          path_id = list(type = "string", enum = I(ontology$path_id)),
          role = list(type = "string", enum = I(c("PRIMARY", "SECONDARY"))),
          reason = list(type = "string")
        ),
        required = c("path_id", "role", "reason"),
        additionalProperties = FALSE
      )
    ),
    review_required = list(type = "boolean"),
    review_reason = list(type = c("string", "null"))
  ),
  required = c("assignments", "review_required", "review_reason"),
  additionalProperties = FALSE
)

extract_output_text <- function(response) {
  message_items <- response$output[
    vapply(response$output, function(item) identical(item$type, "message"), logical(1))
  ]
  content_items <- unlist(lapply(message_items, function(item) item$content), recursive = FALSE)
  text_items <- content_items[
    vapply(content_items, function(item) identical(item$type, "output_text") && !is.null(item$text), logical(1))
  ]
  if (!length(text_items)) stop("No output_text item was returned")
  text_items[[1]]$text
}

classify_record <- function(sampling_stratum, record_sequence, record_id, title, abstract) {
  user_prompt <- paste0(
    "ONTOLOGY\n\n", ontology_prompt,
    "\n\nRECORD\n\nTitle: ", title,
    "\n\nAbstract: ", abstract,
    "\n\nReturn the substantive ontology assignments."
  )

  body <- list(
    model = model,
    store = FALSE,
    reasoning = list(effort = reasoning_effort),
    input = list(
      list(role = "system", content = list(list(type = "input_text", text = system_prompt))),
      list(role = "user", content = list(list(type = "input_text", text = user_prompt)))
    ),
    text = list(
      verbosity = "low",
      format = list(type = "json_schema", name = "topic_v4", strict = TRUE, schema = response_schema)
    )
  )

  parsed <- tryCatch({
    response <- httr2::request("https://api.openai.com/v1/responses") |>
      httr2::req_auth_bearer_token(api_key) |>
      httr2::req_body_json(body, auto_unbox = TRUE) |>
      httr2::req_timeout(180) |>
      httr2::req_retry(max_tries = 4, backoff = ~ 2^.x) |>
      httr2::req_perform() |>
      httr2::resp_body_json()
    jsonlite::fromJSON(extract_output_text(response), simplifyVector = FALSE)
  }, error = function(e) {
    structure(list(message = conditionMessage(e)), class = "classification_error")
  })

  if (inherits(parsed, "classification_error")) {
    return(list(
      record = tibble::tibble(
        sampling_stratum = sampling_stratum, record_sequence = record_sequence,
        record_id = record_id, title = title, abstract = abstract,
        assigned_path_ids = NA_character_, assigned_paths = NA_character_, assigned_path_roles = NA_character_, assignment_count = 0L,
        review_required = TRUE, review_reason = NA_character_, status = "failed",
        classification_error = parsed$message
      ),
      long = tibble::tibble()
    ))
  }

  assignments <- parsed$assignments
  ids <- if (!length(assignments)) character() else unique(vapply(assignments, function(x) x$path_id, character(1)))
  invalid_ids <- setdiff(ids, ontology$path_id)
  if (length(invalid_ids)) stop("Model returned invalid path_id(s): ", paste(invalid_ids, collapse = ", "))

  selected <- ontology |>
    dplyr::filter(path_id %in% ids) |>
    dplyr::arrange(match(path_id, ids))

  unique_assignments <- if (!length(assignments)) list() else assignments[
    !duplicated(vapply(assignments, function(x) x$path_id, character(1)))
  ]

  long <- if (!length(unique_assignments)) {
    tibble::tibble()
  } else {
    tibble::tibble(
      sampling_stratum = sampling_stratum,
      record_sequence = record_sequence,
      record_id = record_id,
      title = title,
      abstract = abstract,
      path_id = vapply(unique_assignments, function(x) x$path_id, character(1)),
      role = vapply(unique_assignments, function(x) x$role, character(1)),
      reason = vapply(unique_assignments, function(x) x$reason, character(1))
    ) |>
      dplyr::left_join(ontology |> dplyr::select(path_id, hierarchy_path), by = "path_id")
  }

  record <- tibble::tibble(
    sampling_stratum = sampling_stratum, record_sequence = record_sequence,
    record_id = record_id, title = title, abstract = abstract,
    assigned_path_ids = if (!nrow(selected)) NA_character_ else paste(selected$path_id, collapse = "; "),
    assigned_paths = if (!nrow(selected)) NA_character_ else paste(selected$hierarchy_path, collapse = "; "),
    assigned_path_roles = if (!length(unique_assignments)) NA_character_ else paste(vapply(unique_assignments, function(x) paste0(x$path_id, "=", x$role), character(1)), collapse = "; "),
    assignment_count = nrow(selected),
    review_required = isTRUE(parsed$review_required),
    review_reason = if (is.null(parsed$review_reason)) NA_character_ else parsed$review_reason,
    status = "completed", classification_error = NA_character_
  )

  list(record = record, long = long)
}

if (file.exists(checkpoint_file)) {
  checkpoint <- readRDS(checkpoint_file)
  record_results <- checkpoint$record_results
  long_results <- checkpoint$long_results
  completed_ids <- unique(record_results$record_id[record_results$status == "completed"])
  message("Resuming V4 topic run: ", length(completed_ids), " / ", nrow(records), " records completed")
} else {
  record_results <- tibble::tibble()
  long_results <- tibble::tibble()
  completed_ids <- character()
  message("Starting V4 topic classification: ", nrow(records), " records; model=", model, "; reasoning=", reasoning_effort)
}

for (i in seq_len(nrow(records))) {
  rid <- records$record_id[[i]]
  if (rid %in% completed_ids) next

  result <- classify_record(
    records$sampling_stratum[[i]], records$record_sequence[[i]], rid,
    records$title[[i]], records$abstract[[i]]
  )
  # Replace any prior attempt for this record so transient failures do not
  # remain in the checkpoint after a successful retry.
  if (nrow(record_results)) record_results <- record_results |> dplyr::filter(record_id != rid)
  if (nrow(long_results) && "record_id" %in% names(long_results)) long_results <- long_results |> dplyr::filter(record_id != rid)
  record_results <- dplyr::bind_rows(record_results, result$record)
  long_results <- dplyr::bind_rows(long_results, result$long)
  if (identical(result$record$status[[1]], "completed")) completed_ids <- unique(c(completed_ids, rid))

  saveRDS(list(record_results = record_results, long_results = long_results), checkpoint_file)
  readr::write_csv(record_results, record_output_file, na = "")
  readr::write_csv(long_results, long_output_file, na = "")
  readr::write_csv(
    record_results |>
      dplyr::transmute(record_id, status, assignment_count, review_required, classification_error),
    progress_file,
    na = ""
  )
  message(i, "/", nrow(records), " ", rid, ": ", result$record$status[[1]], "; assignments=", result$record$assignment_count[[1]])
}

failures <- record_results |> dplyr::filter(status != "completed")
readr::write_csv(failures, failure_file, na = "")
if (nrow(failures)) stop("Topic classification has ", nrow(failures), " failed records; see ", failure_file)

message("Completed V4 topic classification for ", nrow(record_results), " records; assignments: ", nrow(long_results))
