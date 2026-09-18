suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
  library(jsonlite)
  library(httr2)
})

input_path <- Sys.getenv("ADJUDICATION_INPUT_PATH", "")
ontology_path <- Sys.getenv("TOPIC_ONTOLOGY_PATH", "data/reference/topic_ontology_v3_4.csv")
out_dir <- Sys.getenv("ADJUDICATION_OUTPUT_DIR", "")
model <- Sys.getenv("ADJUDICATION_MODEL", "gpt-5.6-terra")
reasoning_effort <- Sys.getenv("ADJUDICATION_REASONING_EFFORT", "medium")

if (!nzchar(input_path) || !file.exists(input_path)) stop("Valid ADJUDICATION_INPUT_PATH is required")
if (!nzchar(out_dir)) stop("ADJUDICATION_OUTPUT_DIR is required")
if (!file.exists(ontology_path)) stop("Ontology file not found: ", ontology_path)
if (!nzchar(Sys.getenv("OPENAI_API_KEY"))) stop("OPENAI_API_KEY is required")

dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
raw_dir <- file.path(out_dir, "raw_responses")
dir.create(raw_dir, recursive = TRUE, showWarnings = FALSE)

review <- readr::read_csv(input_path, show_col_types = FALSE) |>
  dplyr::filter(as.integer(a_b_pathway_exact) == 0L)
ontology <- readr::read_csv(ontology_path, show_col_types = FALSE)

if (nrow(review) != 3L) stop("Expected exactly 3 pathway conflicts, found ", nrow(review))
if (anyDuplicated(review$record_id)) stop("Duplicate record IDs in conflict queue")

ontology_prompt <- paste(
  vapply(seq_len(nrow(ontology)), function(i) {
    row <- ontology[i, ]
    paste0(
      row$path_id, " | ", row$hierarchy_path,
      "\nDefinition: ", row$definition,
      "\nInclude when: ", row$include_when,
      "\nExclude when: ", row$exclude_when,
      "\nInterpretation note: ", row$prompt_logic_note
    )
  }, character(1)),
  collapse = "\n\n"
)

system_prompt <- paste(
  "You are adjudicating conflicts between two independent Luna topic-classification passes for a salmon-aquaculture evidence map.",
  "Assess the title and abstract against the supplied ontology.",
  "Neither Luna pass is presumed correct. Do not select a pass wholesale and do not automatically take the union.",
  "Evaluate every proposed pathway independently and add a pathway missed by both passes if the record and ontology require it.",
  "Assign only pathways that represent substantive research questions, interventions, outcomes or conclusions.",
  "Exclude background concepts, incidental measurements and routine endpoints.",
  "A pathway labelled General is an exclusive fallback: do not assign it when a more specific sibling pathway applies.",
  "Historical coding and human final decisions are deliberately withheld.",
  "Return the final pathway IDs, one concise evidence-based rationale, and a review flag.",
  sep = "\n"
)

schema <- list(
  type = "object",
  properties = list(
    final_path_ids = list(type = "array", items = list(type = "string", enum = I(ontology$path_id))),
    rationale = list(type = "string"),
    review_required = list(type = "boolean"),
    review_reason = list(type = c("string", "null"))
  ),
  required = c("final_path_ids", "rationale", "review_required", "review_reason"),
  additionalProperties = FALSE
)

extract_output_text <- function(response) {
  messages <- response$output[vapply(response$output, function(x) identical(x$type, "message"), logical(1))]
  content <- unlist(lapply(messages, function(x) x$content), recursive = FALSE)
  texts <- content[vapply(content, function(x) identical(x$type, "output_text") && !is.null(x$text), logical(1))]
  if (!length(texts)) stop("No output_text returned")
  texts[[1]]$text
}

results <- vector("list", nrow(review))
for (i in seq_len(nrow(review))) {
  row <- review[i, ]
  disputed_values <- c(
    dplyr::coalesce(as.character(row$a_only), ""),
    dplyr::coalesce(as.character(row$b_only), "")
  )
  disputed <- paste(disputed_values[nzchar(disputed_values)], collapse = "; ")
  user_prompt <- paste0(
    "FULL ONTOLOGY\n\n", ontology_prompt,
    "\n\nRECORD\n\nRecord ID: ", row$record_id,
    "\nTitle: ", row$title,
    "\nAbstract: ", row$abstract,
    "\n\nLUNA PASS A\nAssignments: ", row$luna_a_coding,
    "\nReasons: ", row$luna_a_reasons,
    "\n\nLUNA PASS B\nAssignments: ", row$luna_b_coding,
    "\nReasons: ", row$luna_b_reasons,
    "\n\nDisputed pathway IDs: ", disputed,
    "\n\nAdjudicate the final pathway set."
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
      format = list(type = "json_schema", name = "topic_conflict_adjudication", strict = TRUE, schema = schema)
    )
  )
  response <- httr2::request("https://api.openai.com/v1/responses") |>
    httr2::req_auth_bearer_token(Sys.getenv("OPENAI_API_KEY")) |>
    httr2::req_body_json(body, auto_unbox = TRUE) |>
    httr2::req_timeout(240) |>
    httr2::req_retry(max_tries = 4, backoff = ~ 2^.x) |>
    httr2::req_perform() |>
    httr2::resp_body_json()
  jsonlite::write_json(response, file.path(raw_dir, paste0(row$record_id, ".json")), auto_unbox = TRUE, pretty = TRUE, null = "null")
  parsed <- jsonlite::fromJSON(extract_output_text(response), simplifyVector = FALSE)
  ids <- unique(unlist(parsed$final_path_ids, use.names = FALSE))
  invalid <- setdiff(ids, ontology$path_id)
  if (length(invalid)) stop("Invalid path IDs returned: ", paste(invalid, collapse = ", "))
  results[[i]] <- tibble::tibble(
    record_id = row$record_id,
    title = row$title,
    disputed_path_ids = disputed,
    luna_a_coding = row$luna_a_coding,
    luna_b_coding = row$luna_b_coding,
    terra_final_pathways = paste(ids, collapse = "; "),
    terra_rationale = parsed$rationale,
    terra_review_required = isTRUE(parsed$review_required),
    terra_review_reason = if (is.null(parsed$review_reason)) NA_character_ else parsed$review_reason,
    model = model,
    reasoning_effort = reasoning_effort
  )
}

output <- dplyr::bind_rows(results)
readr::write_csv(output, file.path(out_dir, "terra_conflict_adjudication.csv"), na = "")
readr::write_lines(system_prompt, file.path(out_dir, "terra_adjudication_system_prompt.txt"))
readr::write_lines(ontology_prompt, file.path(out_dir, "terra_adjudication_ontology_prompt.txt"))
manifest <- list(
  records = nrow(output),
  record_ids = output$record_id,
  source = input_path,
  ontology = ontology_path,
  model = model,
  reasoning_effort = reasoning_effort,
  historical_coding_provided = FALSE,
  human_final_decisions_provided = FALSE,
  luna_assignments_and_reasons_provided = TRUE
)
jsonlite::write_json(manifest, file.path(out_dir, "terra_adjudication_manifest.json"), auto_unbox = TRUE, pretty = TRUE)
message("Completed Terra conflict adjudication for ", nrow(output), " records")
