#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(httr2)
  library(jsonlite)
  library(readr)
  library(dplyr)
  library(purrr)
  library(tibble)
})

input_path <- Sys.getenv("ADJUDICATION_INPUT_PATH", "")
ontology_path <- Sys.getenv("TOPIC_ONTOLOGY_PATH", "data/reference/topic_ontology_v3.csv")
policy_path <- Sys.getenv("ADJUDICATION_POLICY_PATH", "data/reference/topic_adjudication_policy_v1.json")
output_dir <- Sys.getenv("ADJUDICATION_OUTPUT_DIR", "")
model <- Sys.getenv("ADJUDICATION_MODEL", "gpt-5.6-luna")
reasoning_effort <- Sys.getenv("ADJUDICATION_REASONING_EFFORT", "medium")

if (!nzchar(input_path) || !file.exists(input_path)) stop("ADJUDICATION_INPUT_PATH missing/not found")
if (!file.exists(ontology_path)) stop("Ontology not found: ", ontology_path)
if (!file.exists(policy_path)) stop("Policy not found: ", policy_path)
if (!nzchar(output_dir)) stop("ADJUDICATION_OUTPUT_DIR is required")
api_key <- Sys.getenv("OPENAI_API_KEY")
if (!nzchar(api_key)) stop("OPENAI_API_KEY not found")

dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

records <- readr::read_csv(input_path, show_col_types = FALSE)
ontology <- readr::read_csv(ontology_path, show_col_types = FALSE)
policy <- jsonlite::fromJSON(policy_path, simplifyVector = FALSE)

required <- c("record_id","title","abstract","pass_a","pass_b","pass_a_reasons","pass_b_reasons")
missing <- setdiff(required, names(records))
if (length(missing)) stop("Input missing columns: ", paste(missing, collapse=", "))
if (anyDuplicated(records$record_id)) stop("Duplicate record_id values in adjudication input")
if (any(!nzchar(records$record_id))) stop("Blank record_id values in adjudication input")

field_line <- function(label, value) {
  value <- dplyr::coalesce(as.character(value), "")
  if (!nzchar(trimws(value))) return(NULL)
  paste0(label, ": ", value)
}

ontology_entries <- purrr::pmap_chr(
  ontology |>
    dplyr::select(path_id, hierarchy_path, definition, include_when, exclude_when,
                  required_subject_terms, required_focus_terms,
                  alternative_standalone_cues, supporting_terms_from_old_ontology,
                  prompt_logic_note),
  function(path_id, hierarchy_path, definition, include_when, exclude_when,
           required_subject_terms, required_focus_terms,
           alternative_standalone_cues, supporting_terms_from_old_ontology,
           prompt_logic_note) {
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
    paste(lines[!vapply(lines, is.null, logical(1))], collapse="\n")
  }
)
ontology_prompt <- paste(ontology_entries, collapse="\n\n")

system_prompt <- paste(
  "You are an ontology-first adjudicator for a systematic map of salmon aquaculture research.",
  "You receive records for which two independent topic-classification passes disagree.",
  "Your task is to produce the best final coding from the record evidence and the supplied ontology.",
  "",
  "RULES",
  "1. The ontology is the governing standard. Apply include_when and exclude_when before labels or lexical cues.",
  "2. Do not systematically prefer Pass A or Pass B.",
  "3. Resolve the actual A/B disagreement. Preserve shared assignments unless there is a substantial ontology error.",
  "4. A substantial ontology error means a shared assignment clearly violates an exclusion rule, fails inclusion/definition criteria, or is materially misclassified.",
  "5. PRIMARY = central research question, intervention, exposure, outcome or conclusion.",
  "6. SECONDARY = independently substantive but non-central. Background, context and incidental measurements are unassigned.",
  "7. Multiple PRIMARY assignments are allowed when genuinely co-primary.",
  "8. Do not assign from title alone. If the abstract is absent or genuinely insufficient, return needs_more_information.",
  "9. Do not use blind union or intersection. Judge every disputed assignment against the ontology and evidence.",
  "10. Return only ontology path_ids supplied below.",
  sep="\n"
)

record_payload <- lapply(seq_len(nrow(records)), function(i) {
  list(
    record_id = records$record_id[[i]],
    title = records$title[[i]],
    abstract = records$abstract[[i]],
    pass_a = records$pass_a[[i]],
    pass_a_reasons = records$pass_a_reasons[[i]],
    pass_b = records$pass_b[[i]],
    pass_b_reasons = records$pass_b_reasons[[i]]
  )
})

user_prompt <- paste0(
  "ONTOLOGY\n\n", ontology_prompt,
  "\n\nRECORDS TO ADJUDICATE\n\n",
  jsonlite::toJSON(record_payload, auto_unbox=TRUE, pretty=FALSE, na="null"),
  "\n\nAdjudicate every record independently."
)

response_schema <- list(
  type="object",
  properties=list(
    adjudications=list(
      type="array",
      items=list(
        type="object",
        properties=list(
          record_id=list(type="string", enum=I(records$record_id)),
          status=list(type="string", enum=I(c("resolved","needs_more_information","unresolved"))),
          assignments=list(
            type="array",
            items=list(
              type="object",
              properties=list(
                path_id=list(type="string", enum=I(ontology$path_id)),
                role=list(type="string", enum=I(c("PRIMARY","SECONDARY")))
              ),
              required=c("path_id","role"),
              additionalProperties=FALSE
            )
          ),
          pass_alignment=list(type="string", enum=I(c("A","B","hybrid","neither"))),
          rationale=list(type="string")
        ),
        required=c("record_id","status","assignments","pass_alignment","rationale"),
        additionalProperties=FALSE
      )
    )
  ),
  required=I(c("adjudications")),
  additionalProperties=FALSE
)

extract_output_text <- function(response) {
  message_items <- response$output[vapply(response$output, function(x) identical(x$type,"message"), logical(1))]
  content_items <- unlist(lapply(message_items, function(x) x$content), recursive=FALSE)
  text_items <- content_items[vapply(content_items, function(x) identical(x$type,"output_text") && !is.null(x$text), logical(1))]
  if (!length(text_items)) stop("No output_text returned")
  text_items[[1]]$text
}

body <- list(
  model=model,
  store=FALSE,
  reasoning=list(effort=reasoning_effort),
  input=list(
    list(role="system", content=list(list(type="input_text", text=system_prompt))),
    list(role="user", content=list(list(type="input_text", text=user_prompt)))
  ),
  text=list(
    verbosity="low",
    format=list(type="json_schema", name="topic_adjudication_batch", strict=TRUE, schema=response_schema)
  )
)

resp <- httr2::request("https://api.openai.com/v1/responses") |>
  httr2::req_auth_bearer_token(api_key) |>
  httr2::req_body_json(body, auto_unbox=TRUE) |>
  httr2::req_timeout(600) |>
  httr2::req_retry(max_tries=4, backoff=~2^.x) |>
  httr2::req_error(is_error = function(resp) FALSE) |>
  httr2::req_perform()

if (httr2::resp_status(resp) >= 400) {
  err <- httr2::resp_body_string(resp)
  writeLines(err, file.path(output_dir, "api_error.txt"))
  stop("OpenAI API returned HTTP ", httr2::resp_status(resp), ": ", err)
}
response <- httr2::resp_body_json(resp)

parsed <- jsonlite::fromJSON(extract_output_text(response), simplifyVector=FALSE)
adj <- parsed$adjudications
ids <- vapply(adj, function(x) x$record_id, character(1))
if (length(ids) != nrow(records)) stop("Adjudicator returned ", length(ids), " rows; expected ", nrow(records))
if (anyDuplicated(ids)) stop("Adjudicator returned duplicate record_ids")
if (!setequal(ids, records$record_id)) stop("Adjudicator record_ids do not match input")

rows <- lapply(adj, function(x) {
  assignments <- x$assignments
  coding <- if (!length(assignments)) "" else paste(
    vapply(assignments, function(a) paste0(a$path_id,"=",a$role), character(1)),
    collapse="; "
  )
  tibble::tibble(
    record_id=x$record_id,
    status=x$status,
    final_coding=coding,
    pass_alignment=x$pass_alignment,
    rationale=x$rationale
  )
}) |> dplyr::bind_rows() |>
  dplyr::left_join(records |> dplyr::select(record_id,title), by="record_id")

readr::write_csv(rows, file.path(output_dir,"adjudications.csv"), na="")
jsonlite::write_json(response$usage, file.path(output_dir,"usage.json"), auto_unbox=TRUE, pretty=TRUE)
readr::write_lines(system_prompt, file.path(output_dir,"system_prompt.txt"))
readr::write_lines(ontology_prompt, file.path(output_dir,"ontology_prompt.txt"))

message("PASS: adjudicated ", nrow(rows), " records in one batch request")
