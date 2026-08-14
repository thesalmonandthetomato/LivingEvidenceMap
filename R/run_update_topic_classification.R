suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
  library(stringr)
  library(tibble)
  library(jsonlite)
  library(httr2)
})

input_path <- "data/updates/2026-08-13_lens/records_after_species_geography_adjudication.csv"
ontology_path <- "data/reference/topic_ontology_v3.csv"
out_dir <- "data/updates/2026-08-13_lens/topic_classification_v3"
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
checkpoint_path <- file.path(out_dir, "topic_assignments_checkpoint.csv")
final_path <- file.path(out_dir, "topic_assignments.csv")
review_path <- file.path(out_dir, "topic_review_queue.csv")

api_key <- Sys.getenv("OPENAI_API_KEY")
if (!nzchar(api_key)) stop("OPENAI_API_KEY not found")

records <- readr::read_csv(input_path, show_col_types = FALSE)
ontology <- readr::read_csv(ontology_path, show_col_types = FALSE)

lens_col <- intersect(c("lens_id", "Lens ID", "lensId", "LensID", "lens_record_id"), names(records))[1]
if (is.na(lens_col)) stop("No Lens ID column found in update")
title_col <- intersect(c("title", "Title", "document_title", "Document Title"), names(records))[1]
abstract_col <- intersect(c("abstract", "Abstract", "abstract_text", "Abstract Text"), names(records))[1]
record_col <- intersect(c("record_id", "Record ID", "id", "ID"), names(records))[1]
if (is.na(title_col) || is.na(abstract_col)) stop("Could not identify title/abstract columns")
if (is.na(record_col)) {
  records$record_id <- seq_len(nrow(records))
  record_col <- "record_id"
}

required_ontology <- c("path_id", "level_1", "level_2", "level_3", "hierarchy_path", "supporting_terms_from_old_ontology")
missing <- setdiff(required_ontology, names(ontology))
if (length(missing)) stop("Ontology missing columns: ", paste(missing, collapse = ", "))

ontology <- ontology %>%
  mutate(
    cue_terms = coalesce(supporting_terms_from_old_ontology, ""),
    prompt_line = paste0(hierarchy_path, " [", path_id, "] | Semantic cues: ", cue_terms)
  )
valid_paths <- ontology$hierarchy_path

classify_one <- function(title, abstract) {
  system_prompt <- paste(
    "You are classifying scientific abstracts for a systematic evidence map of farmed salmon and rainbow trout research.",
    "Select every valid three-level hierarchy path listed below that represents a substantive objective, intervention, exposure, measured outcome, interpretation or application of the study.",
    "A path need not be the primary focus to be substantive.",
    "Semantic cues are non-exhaustive and do not require literal matching.",
    "Do not assign a path from an isolated word, background mention, or motivation alone.",
    "Use only the listed hierarchy paths. Multiple paths are allowed when genuinely applicable.",
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
    "VALID HIERARCHY PATHS\n", paste(ontology$prompt_line, collapse = "\n"),
    "\n\nTITLE\n", coalesce(title, ""),
    "\n\nABSTRACT\n", coalesce(abstract, ""),
    "\n\nSelect every substantively applicable hierarchy path."
  )
  body <- list(
    model = "gpt-5-mini", store = FALSE,
    input = list(
      list(role = "system", content = list(list(type = "input_text", text = system_prompt))),
      list(role = "user", content = list(list(type = "input_text", text = user_prompt)))
    ),
    text = list(format = list(type = "json_schema", name = "topic_hierarchy_classification",
                              strict = TRUE, schema = schema))
  )
  response <- request("https://api.openai.com/v1/responses") %>%
    req_auth_bearer_token(api_key) %>%
    req_body_json(body, auto_unbox = TRUE) %>%
    req_timeout(180) %>%
    req_retry(max_tries = 3, backoff = ~ 2^.x) %>%
    req_error(is_error = function(resp) FALSE) %>%
    req_perform()
  status <- resp_status(response)
  if (status >= 400L) stop("OpenAI HTTP ", status, ": ", resp_body_string(response))
  response <- resp_body_json(response)
  if (!identical(response$status, "completed")) stop("OpenAI response status: ", response$status)
  messages <- response$output[vapply(response$output, function(x) identical(x$type, "message"), logical(1))]
  content <- unlist(lapply(messages, function(x) x$content), recursive = FALSE)
  text_items <- content[vapply(content, function(x) identical(x$type, "output_text") && !is.null(x$text), logical(1))]
  if (!length(text_items)) stop("No output_text in OpenAI response")
  parsed <- jsonlite::fromJSON(text_items[[1]]$text)
  bad <- setdiff(parsed$assignments, valid_paths)
  if (length(bad)) stop("Invalid paths: ", paste(bad, collapse = "; "))
  list(assignments = parsed$assignments,
       review_required = isTRUE(parsed$review_required),
       review_reason = if (is.null(parsed$review_reason)) NA_character_ else parsed$review_reason)
}

if (file.exists(checkpoint_path)) {
  checkpoint <- readr::read_csv(checkpoint_path, show_col_types = FALSE)
} else {
  checkpoint <- tibble(record_id = character(), lens_id = character(), path_id = character(), hierarchy_path = character(), review_required = logical(), review_reason = character(), status = character(), error = character())
}

done_keys <- unique(checkpoint$record_id[checkpoint$status == "completed"])
message("Records: ", nrow(records), "; completed checkpoint records: ", length(done_keys))

for (i in seq_len(nrow(records))) {
  rid <- as.character(records[[record_col]][i])
  if (rid %in% done_keys) next
  lens_id <- as.character(records[[lens_col]][i])
  result <- tryCatch(classify_one(records[[title_col]][i], records[[abstract_col]][i]), error = function(e) list(error = conditionMessage(e)))
  if (!is.null(result$error)) {
    rows <- tibble(record_id = rid, lens_id = lens_id, path_id = NA_character_, hierarchy_path = NA_character_, review_required = NA, review_reason = NA_character_, status = "failed", error = result$error)
  } else if (!length(result$assignments)) {
    rows <- tibble(record_id = rid, lens_id = lens_id, path_id = NA_character_, hierarchy_path = NA_character_, review_required = result$review_required, review_reason = result$review_reason, status = "completed", error = NA_character_)
  } else {
    rows <- ontology %>% filter(hierarchy_path %in% result$assignments) %>% transmute(record_id = rid, lens_id = lens_id, path_id, hierarchy_path, review_required = result$review_required, review_reason = result$review_reason, status = "completed", error = NA_character_)
  }
  checkpoint <- bind_rows(checkpoint, rows)
  readr::write_csv(checkpoint, checkpoint_path)
  if (i %% 25 == 0) message("Processed ", i, "/", nrow(records))
}

readr::write_csv(checkpoint, final_path)
review <- checkpoint %>% filter(review_required %in% TRUE | status == "failed")
readr::write_csv(review, review_path)

failed_ids <- checkpoint %>% filter(status == "failed") %>% distinct(record_id)
if (nrow(failed_ids)) stop("Topic classification has ", nrow(failed_ids), " failed records; see ", review_path)

message("Completed topic classification for ", n_distinct(checkpoint$record_id), " records; assignments: ", sum(!is.na(checkpoint$path_id)))
