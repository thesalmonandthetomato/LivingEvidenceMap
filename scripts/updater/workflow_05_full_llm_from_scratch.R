#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(dplyr)
  library(fs)
  library(httr2)
  library(jsonlite)
  library(tibble)
})

# One-off/full-corpus Workflow 05 model annotation.
#
# IMPORTANT: this intentionally ignores the production master and all previous
# species/geography annotations. Every downstream-eligible record that passed
# Workflow 04 is annotated afresh from title + abstract only.

args <- commandArgs(trailingOnly = TRUE)
arg <- function(flag, default = NULL) {
  i <- match(flag, args)
  if (is.na(i)) return(default)
  if (i == length(args)) stop(sprintf("Missing value after %s", flag), call. = FALSE)
  args[[i + 1L]]
}

input_path <- arg("--input")
output_dir <- arg("--output-dir", "outputs/workflow05-full-llm")
model <- arg("--model", "gpt-5-mini")
chunk_index <- as.integer(arg("--chunk-index", "0"))
chunk_count <- as.integer(arg("--chunk-count", "1"))

if (is.null(input_path) || !file.exists(input_path)) stop("Valid --input is required", call. = FALSE)
if (is.na(chunk_index) || is.na(chunk_count) || chunk_count < 1L || chunk_index < 0L || chunk_index >= chunk_count) {
  stop("Invalid chunk index/count", call. = FALSE)
}
api_key <- Sys.getenv("OPENAI_API_KEY")
if (!nzchar(api_key)) stop("OPENAI_API_KEY is required", call. = FALSE)

dir_create(output_dir, recurse = TRUE)
`%||%` <- function(x, y) if (is.null(x)) y else x
clean <- function(x) {
  x <- as.character(x)
  x[is.na(x)] <- ""
  trimws(x)
}
textify <- function(x) {
  if (is.null(x)) return("")
  if (is.character(x) || is.atomic(x)) return(paste(clean(x)[nzchar(clean(x))], collapse = "; "))
  if (is.list(x)) return(paste(Filter(nzchar, vapply(x, textify, character(1))), collapse = "; "))
  clean(x)
}
first_nonempty <- function(...) {
  for (x in list(...)) {
    z <- textify(x)
    if (nzchar(z)) return(z)
  }
  ""
}
now_utc <- function() format(Sys.time(), tz = "UTC", format = "%Y-%m-%dT%H:%M:%SZ")

read_jsonl <- function(path) {
  lines <- readLines(path, warn = FALSE, encoding = "UTF-8")
  lines <- lines[nzchar(trimws(lines))]
  lapply(seq_along(lines), function(i) {
    tryCatch(fromJSON(lines[[i]], simplifyVector = FALSE),
      error = function(e) stop(sprintf("Invalid JSONL line %d: %s", i, conditionMessage(e)), call. = FALSE))
  })
}

lens_id_of <- function(r) first_nonempty((r$identity %||% list())$lens_id,
  (r$canonical %||% list())$lens_id,
  (r$lens %||% list())$lens_id)
title_of <- function(r) first_nonempty((r$canonical %||% list())$title,
  ((r$lens %||% list())$raw_payload %||% list())$title)
abstract_of <- function(r) first_nonempty((r$canonical %||% list())$abstract,
  ((r$lens %||% list())$raw_payload %||% list())$abstract)
publication_ok <- function(r) {
  n <- r$notices
  if (is.null(n)) return(TRUE)
  isTRUE(n$record_downstream_eligible %||% n$downstream_eligible %||% TRUE)
}
dedup_ok <- function(r) {
  status <- tolower(first_nonempty((r$deduplication %||% list())$status))
  status %in% c("unique", "canonical")
}
screen_decision <- function(r) tolower(first_nonempty((r$screening %||% list())$decision))

records_all <- read_jsonl(input_path)
eligible_idx <- which(vapply(records_all, function(r) {
  dedup_ok(r) && publication_ok(r) && screen_decision(r) %in% c("include", "uncertain")
}, logical(1)))

records <- tibble(
  record_sequence = seq_along(eligible_idx),
  canonical_index = eligible_idx,
  record_id = vapply(records_all[eligible_idx], lens_id_of, character(1)),
  title = vapply(records_all[eligible_idx], title_of, character(1)),
  abstract = vapply(records_all[eligible_idx], abstract_of, character(1)),
  screening_decision = vapply(records_all[eligible_idx], screen_decision, character(1))
)
if (any(!nzchar(records$record_id))) stop("Every forwarded record must have a Lens ID", call. = FALSE)
if (anyDuplicated(records$record_id)) stop("Forwarded Lens IDs are not unique", call. = FALSE)

# Stable modulo partition: every record appears in exactly one chunk.
chunk_rows <- records$record_sequence %% chunk_count == chunk_index
chunk <- records[chunk_rows, , drop = FALSE]
message(sprintf("Workflow 05 full LLM: total forwarded=%d; chunk=%d/%d; chunk records=%d; model=%s",
  nrow(records), chunk_index + 1L, chunk_count, nrow(chunk), model))

system_prompt <- paste(
  "You are annotating species and primary study geography for a salmon-farming evidence map.",
  "This is a fresh annotation. Use ONLY the supplied title and abstract. Do not assume or reuse any previous annotation.",
  "",
  "SPECIES:",
  "Return all eligible salmonid species that are substantive study subjects in the record, using only these IDs:",
  "SAL_SALAR = Atlantic salmon (Salmo salar).",
  "ONC_MYKISS = rainbow trout/steelhead (Oncorhynchus mykiss).",
  "ONC_TSHAWYTSCHA = Chinook salmon.",
  "ONC_KISUTCH = coho salmon.",
  "ONC_NERKA = sockeye salmon.",
  "ONC_KETA = chum salmon.",
  "ONC_GORBUSCHA = pink salmon.",
  "ONC_MASOU = masu salmon.",
  "UNSPEC_SALMON = farmed salmon where the salmon species is genuinely unspecified.",
  "Do not assign an eligible species merely because it appears as a background example, citation context, ingredient, comparison, or incidental mention.",
  "Do not infer a specific species from generic salmon. If the record genuinely concerns farmed salmon but species is unspecified, use UNSPEC_SALMON.",
  "If no eligible salmonid can be defensibly assigned from title/abstract, return an empty species_ids array and species_status UNRESOLVED.",
  "",
  "GEOGRAPHY:",
  "Identify the primary country or countries where the study itself was conducted or the focal production system/population is located.",
  "Do not use author affiliations, supplier/manufacturer locations, literature/background mentions, comparison countries, or market destinations unless they are themselves the substantive study geography.",
  "A country explicitly named in the title is strong evidence of primary geography. Multiple countries may be returned when the study substantively covers each.",
  "Return ISO 3166-1 alpha-3 codes only.",
  "If the study has no defensible country-level primary geography, return an empty array and geography_status NONE.",
  "If the text is genuinely ambiguous between competing country assignments, use geography_status UNRESOLVED.",
  "",
  "Give concise evidence-based reasons. Do not invent information absent from the title/abstract.",
  sep = "\n"
)

schema <- list(
  type = "object",
  properties = list(
    species_status = list(type = "string", enum = c("RESOLVED", "UNRESOLVED")),
    species_ids = list(type = "array", items = list(type = "string", enum = c(
      "SAL_SALAR", "ONC_MYKISS", "ONC_TSHAWYTSCHA", "ONC_KISUTCH", "ONC_NERKA",
      "ONC_KETA", "ONC_GORBUSCHA", "ONC_MASOU", "UNSPEC_SALMON"
    ))),
    species_reason = list(type = "string"),
    geography_status = list(type = "string", enum = c("RESOLVED", "NONE", "UNRESOLVED")),
    primary_country_iso3c = list(type = "array", items = list(type = "string")),
    geography_reason = list(type = "string")
  ),
  required = c("species_status", "species_ids", "species_reason", "geography_status", "primary_country_iso3c", "geography_reason"),
  additionalProperties = FALSE
)

extract_output_text <- function(x) {
  if (!is.null(x$output_text) && nzchar(textify(x$output_text))) return(textify(x$output_text))
  if (!is.null(x$output) && is.list(x$output)) {
    for (item in x$output) {
      if (!is.null(item$content) && is.list(item$content)) {
        for (part in item$content) {
          if (identical(part$type %||% "", "output_text") && nzchar(part$text %||% "")) return(part$text)
        }
      }
    }
  }
  stop("OpenAI response contained no output_text", call. = FALSE)
}

call_model <- function(title, abstract) {
  user_prompt <- paste("TITLE", title, "", "ABSTRACT", abstract, sep = "\n")
  body <- list(
    model = model,
    store = FALSE,
    reasoning = list(effort = "low"),
    input = list(
      list(role = "system", content = list(list(type = "input_text", text = system_prompt))),
      list(role = "user", content = list(list(type = "input_text", text = user_prompt)))
    ),
    text = list(verbosity = "low", format = list(
      type = "json_schema", name = "workflow05_fresh_species_geography", strict = TRUE, schema = schema
    ))
  )
  resp <- httr2::request("https://api.openai.com/v1/responses") |>
    httr2::req_auth_bearer_token(api_key) |>
    httr2::req_body_json(body, auto_unbox = TRUE) |>
    httr2::req_timeout(120) |>
    httr2::req_retry(max_tries = 5, backoff = ~ min(60, 2^.x)) |>
    httr2::req_perform() |>
    httr2::resp_body_json(simplifyVector = FALSE)
  jsonlite::fromJSON(extract_output_text(resp), simplifyVector = TRUE)
}

result_path <- path(output_dir, sprintf("workflow05_full_llm_chunk_%02d.jsonl", chunk_index))
summary_path <- path(output_dir, sprintf("workflow05_full_llm_chunk_%02d_summary.json", chunk_index))
if (file.exists(result_path)) file_delete(result_path)

failures <- 0L
start_time <- Sys.time()
for (i in seq_len(nrow(chunk))) {
  row <- chunk[i, , drop = FALSE]
  ans <- tryCatch(call_model(row$title[[1]], row$abstract[[1]]), error = function(e) e)
  if (inherits(ans, "error")) {
    failures <- failures + 1L
    out <- list(
      record_sequence = row$record_sequence[[1]], record_id = row$record_id[[1]],
      screening_decision = row$screening_decision[[1]], model = model,
      annotated_at = now_utc(), llm_failed = TRUE, llm_error = conditionMessage(ans),
      species_status = "UNRESOLVED", species_ids = list(), species_reason = "",
      geography_status = "UNRESOLVED", primary_country_iso3c = list(), geography_reason = ""
    )
  } else {
    out <- list(
      record_sequence = row$record_sequence[[1]], record_id = row$record_id[[1]],
      screening_decision = row$screening_decision[[1]], model = model,
      annotated_at = now_utc(), llm_failed = FALSE, llm_error = "",
      species_status = ans$species_status, species_ids = as.list(ans$species_ids), species_reason = ans$species_reason,
      geography_status = ans$geography_status, primary_country_iso3c = as.list(ans$primary_country_iso3c), geography_reason = ans$geography_reason
    )
  }
  cat(toJSON(out, auto_unbox = TRUE, null = "null", na = "null"), "\n", file = result_path, append = TRUE, sep = "")
  if (i == 1L || i %% 25L == 0L || i == nrow(chunk)) {
    message(sprintf("Chunk %d: %d/%d (%.1f%%); technical failures=%d", chunk_index, i, nrow(chunk), 100 * i / max(1, nrow(chunk)), failures))
  }
}

summary <- list(
  workflow = "workflow05_full_llm_from_scratch",
  completed_at = now_utc(),
  input = input_path,
  model = model,
  total_forwarded_records = nrow(records),
  chunk_index = chunk_index,
  chunk_count = chunk_count,
  chunk_records = nrow(chunk),
  llm_calls_attempted = nrow(chunk),
  technical_failures = failures,
  elapsed_seconds = as.numeric(difftime(Sys.time(), start_time, units = "secs")),
  master_reuse = FALSE,
  deterministic_annotation_reuse = FALSE,
  fresh_title_abstract_annotation = TRUE
)
writeLines(toJSON(summary, auto_unbox = TRUE, pretty = TRUE, na = "null"), summary_path)
message(sprintf("Chunk %d complete: %d records, %d technical failures.", chunk_index, nrow(chunk), failures))
