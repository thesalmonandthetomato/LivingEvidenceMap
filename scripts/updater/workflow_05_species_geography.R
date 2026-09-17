#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(dplyr)
  library(fs)
  library(here)
  library(httr2)
  library(jsonlite)
  library(purrr)
  library(readr)
  library(stringi)
  library(stringr)
  library(tibble)
})

# Workflow 05: species + primary-study geography annotation.
#
# Canonical JSONL from Workflow 04 is the pipeline input and canonical JSONL is
# the output. Records with screening decision INCLUDE or UNCERTAIN continue;
# EXCLUDE records are preserved unchanged and are not annotated.
#
# Existing production-master annotations may be reused to avoid repeating paid
# adjudication. Deterministic annotation is then applied to missing dimensions.
# LLM adjudication is optional and may only act on genuinely unresolved,
# non-reused dimensions. Substantive uncertainty is preserved for the combined
# post-topic human-review gate; Workflow 05 itself does not email or halt on it.

source("scripts/setup_pipeline.R")
source("R/species_detect.R")
source("R/species_filter.R")
source("R/species_assign.R")
source("R/species_annotation.R")
source("R/geography_detect.R")
source("R/geography_primary_country.R")
source("R/llm_adjudication.R")

args <- commandArgs(trailingOnly = TRUE)
arg <- function(flag, default = NULL) {
  i <- match(flag, args)
  if (is.na(i)) return(default)
  if (i == length(args)) stop(sprintf("Missing value after %s", flag), call. = FALSE)
  args[[i + 1L]]
}

input_path <- arg("--input")
master_path <- arg("--master", "data/master/current/living_evidence_map_master.csv")
output_dir <- arg("--output-dir", "outputs/workflow05")
llm_mode <- arg("--llm-mode", "off")
model <- arg("--model", Sys.getenv("OPENAI_ANNOTATION_MODEL", "gpt-5-mini"))
max_llm_records <- as.integer(arg("--max-llm-records", "0"))

if (is.null(input_path)) stop("--input is required", call. = FALSE)
if (!file.exists(input_path)) stop("Canonical JSONL does not exist: ", input_path, call. = FALSE)
if (!file.exists(master_path)) stop("Master CSV does not exist: ", master_path, call. = FALSE)
if (!llm_mode %in% c("off", "new-only")) stop("--llm-mode must be off or new-only", call. = FALSE)
if (is.na(max_llm_records) || max_llm_records < 0L) stop("--max-llm-records must be >= 0", call. = FALSE)
if (llm_mode == "new-only" && !nzchar(Sys.getenv("OPENAI_API_KEY"))) {
  stop("OPENAI_API_KEY is required when --llm-mode=new-only", call. = FALSE)
}

dir_create(output_dir, recurse = TRUE)
now_utc <- function() format(Sys.time(), tz = "UTC", format = "%Y-%m-%dT%H:%M:%SZ")
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
first_col <- function(df, candidates) {
  hit <- candidates[candidates %in% names(df)]
  if (!length(hit)) return(rep("", nrow(df)))
  out <- rep("", nrow(df))
  for (nm in hit) {
    x <- clean(df[[nm]])
    take <- !nzchar(out) & nzchar(x)
    out[take] <- x[take]
  }
  out
}
normalise_doi <- function(x) {
  x <- tolower(clean(x))
  x <- sub("^https?://(dx\\.)?doi\\.org/", "", x)
  x <- sub("^doi:\\s*", "", x)
  x
}
normalise_title <- function(x) {
  x <- tolower(clean(x))
  x <- stringi::stri_trans_general(x, "Latin-ASCII")
  x <- gsub("[^[:alnum:]]+", " ", x)
  stringr::str_squish(x)
}

read_jsonl <- function(path) {
  lines <- readLines(path, warn = FALSE, encoding = "UTF-8")
  lines <- lines[nzchar(trimws(lines))]
  lapply(seq_along(lines), function(i) {
    tryCatch(fromJSON(lines[[i]], simplifyVector = FALSE),
             error = function(e) stop(sprintf("Invalid JSONL line %d: %s", i, conditionMessage(e)), call. = FALSE))
  })
}

message("Workflow 05: loading canonical JSONL.")
canonical_records <- read_jsonl(input_path)
if (!length(canonical_records)) stop("Canonical JSONL is empty", call. = FALSE)

lens_id_of <- function(r) first_nonempty((r$identity %||% list())$lens_id,
                                         (r$canonical %||% list())$lens_id,
                                         (r$lens %||% list())$lens_id)
doi_of <- function(r) first_nonempty((r$canonical %||% list())$doi,
                                     (r$identity %||% list())$doi,
                                     ((r$lens %||% list())$raw_payload %||% list())$doi)
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

screen_counts <- table(factor(vapply(canonical_records, screen_decision, character(1)),
                              levels = c("include", "uncertain", "exclude", "")))
eligible_idx <- which(vapply(canonical_records, function(r) {
  dedup_ok(r) && publication_ok(r) && screen_decision(r) %in% c("include", "uncertain")
}, logical(1)))

message(sprintf(
  "Workflow 05: canonical records=%d; screening include=%d uncertain=%d exclude=%d; downstream annotation set=%d.",
  length(canonical_records), screen_counts[["include"]], screen_counts[["uncertain"]],
  screen_counts[["exclude"]], length(eligible_idx)
))

records <- tibble(
  record_sequence = seq_along(eligible_idx),
  canonical_index = eligible_idx,
  record_id = vapply(canonical_records[eligible_idx], lens_id_of, character(1)),
  lens_id = vapply(canonical_records[eligible_idx], lens_id_of, character(1)),
  doi = vapply(canonical_records[eligible_idx], doi_of, character(1)),
  title = vapply(canonical_records[eligible_idx], title_of, character(1)),
  abstract = vapply(canonical_records[eligible_idx], abstract_of, character(1)),
  screening_decision = vapply(canonical_records[eligible_idx], screen_decision, character(1))
)
if (any(!nzchar(records$record_id))) stop("Every downstream canonical record must have a Lens ID", call. = FALSE)
if (anyDuplicated(records$record_id)) stop("Downstream canonical Lens IDs are not unique", call. = FALSE)

message("Workflow 05: loading production master for annotation reuse.")
master <- read_csv(master_path, show_col_types = FALSE, progress = FALSE)
master$.lens_key <- tolower(first_col(master, c("lens_id", "Lens ID", "LensID", "record_id")))
master$.doi_key <- normalise_doi(first_col(master, c("doi", "DOI", "doi_id")))
master$.title_key <- normalise_title(first_col(master, c("title", "Title", "document_title", "Document Title")))
master$.species_value <- first_col(master, c(
  "final_species", "species_final", "final_farmed_species", "adjudicated_species",
  "llm_species", "deterministic_species", "species"
))
master$.geo_iso3c <- first_col(master, c(
  "final_primary_country_iso3c", "primary_country_iso3c_final",
  "adjudicated_primary_country_iso3c", "llm_primary_country_iso3c",
  "deterministic_primary_iso3c", "primary_iso3c"
))
master$.geo_country <- first_col(master, c(
  "final_primary_country", "final_primary_countries", "primary_country_final",
  "deterministic_primary_countries", "primary_countries", "country"
))

unique_index <- function(values) {
  ok <- nzchar(values)
  tab <- table(values[ok])
  uniq <- names(tab)[tab == 1L]
  idx <- which(ok & values %in% uniq)
  setNames(idx, values[idx])
}
lens_index <- unique_index(master$.lens_key)
doi_index <- unique_index(master$.doi_key)
title_index <- unique_index(master$.title_key)

records$.lens_key <- tolower(records$lens_id)
records$.doi_key <- normalise_doi(records$doi)
records$.title_key <- normalise_title(records$title)
match_master_row <- function(i) {
  k <- records$.lens_key[[i]]
  if (nzchar(k) && k %in% names(lens_index)) return(unname(lens_index[[k]]))
  k <- records$.doi_key[[i]]
  if (nzchar(k) && k %in% names(doi_index)) return(unname(doi_index[[k]]))
  k <- records$.title_key[[i]]
  if (nzchar(k) && k %in% names(title_index)) return(unname(title_index[[k]]))
  NA_integer_
}
master_match <- vapply(seq_len(nrow(records)), match_master_row, integer(1))

reuse <- tibble(
  record_id = records$record_id,
  master_match_row = master_match,
  master_species = ifelse(is.na(master_match), "", master$.species_value[master_match]),
  master_primary_country_iso3c = ifelse(is.na(master_match), "", master$.geo_iso3c[master_match]),
  master_primary_countries = ifelse(is.na(master_match), "", master$.geo_country[master_match])
) |>
  mutate(
    across(starts_with("master_"), clean),
    master_match = !is.na(master_match_row),
    species_reused = nzchar(master_species),
    geography_reused = nzchar(master_primary_country_iso3c)
  )
write_csv(reuse, path(output_dir, "master_annotation_reuse.csv"), na = "")

species_records <- records |>
  inner_join(reuse |> filter(!species_reused) |> select(record_id), by = "record_id") |>
  select(record_sequence, record_id, title, abstract)
geo_records <- records |>
  inner_join(reuse |> filter(!geography_reused) |> select(record_id), by = "record_id") |>
  select(record_sequence, record_id, title, abstract)

species_dictionary <- read_csv(here("config", "species_dictionary.csv"), show_col_types = FALSE, progress = FALSE)
gazetteer <- read_csv(here("config", "global_country_gazetteer_v3.csv"), show_col_types = FALSE, progress = FALSE)

message(sprintf("Workflow 05: deterministic species annotation on %d records.", nrow(species_records)))
if (nrow(species_records)) {
  species <- annotate_species(species_records, species_dictionary, progress = TRUE)
} else {
  species <- list(species_mentions = tibble(), species_assignments = tibble(), failures = tibble())
}
if (nrow(species$failures)) stop("Technical species-annotation failures occurred", call. = FALSE)
write_csv(species$species_mentions, path(output_dir, "species_mentions.csv"), na = "")
write_csv(species$species_assignments, path(output_dir, "species_assignments.csv"), na = "")
write_csv(species$failures, path(output_dir, "species_annotation_failures.csv"), na = "")

message(sprintf("Workflow 05: deterministic geography annotation on %d records.", nrow(geo_records)))
if (nrow(geo_records)) {
  geo_mentions <- detect_geography_mentions(geo_records, gazetteer, progress = TRUE)
  geo <- if (nrow(geo_mentions)) assign_primary_country(geo_mentions) else
    list(ranking = tibble(), assignments = tibble(), summary = tibble(), review_queue = tibble())
} else {
  geo_mentions <- tibble()
  geo <- list(ranking = tibble(), assignments = tibble(), summary = tibble(), review_queue = tibble())
}
write_csv(geo_mentions, path(output_dir, "geography_mentions.csv"), na = "")
write_csv(geo$ranking, path(output_dir, "geography_ranking.csv"), na = "")
write_csv(geo$assignments, path(output_dir, "geography_assignments.csv"), na = "")
write_csv(geo$summary, path(output_dir, "geography_summary.csv"), na = "")
write_csv(geo$review_queue, path(output_dir, "geography_review_queue.csv"), na = "")

if (nrow(species$species_assignments)) {
  sp <- species$species_assignments |>
    group_by(record_id) |>
    summarise(
      deterministic_species = paste(sort(unique(clean(farmed_species)[nzchar(clean(farmed_species))])), collapse = "; "),
      deterministic_species_ids = paste(sort(unique(clean(farmed_species_id)[nzchar(clean(farmed_species_id))])), collapse = "; "),
      species_review_required = any(review_required %in% TRUE),
      species_reasons = paste(sort(unique(clean(assignment_reason)[nzchar(clean(assignment_reason))])), collapse = " | "),
      non_target_species = paste(sort(unique(clean(non_target_species)[nzchar(clean(non_target_species))])), collapse = "; "),
      .groups = "drop"
    )
} else {
  sp <- tibble(record_id=character(), deterministic_species=character(), deterministic_species_ids=character(), species_review_required=logical(), species_reasons=character(), non_target_species=character())
}

if (nrow(geo$summary)) {
  gs <- geo$summary |>
    transmute(record_id=as.character(record_id),
              deterministic_primary_countries=clean(primary_countries),
              deterministic_primary_iso3c=clean(primary_iso3c),
              geography_review_required=review_required %in% TRUE,
              geography_review_reason=clean(review_reason))
} else {
  gs <- tibble(record_id=character(), deterministic_primary_countries=character(), deterministic_primary_iso3c=character(), geography_review_required=logical(), geography_review_reason=character())
}

state <- reuse |>
  left_join(sp, by="record_id") |>
  left_join(gs, by="record_id") |>
  mutate(
    deterministic_species = coalesce(deterministic_species, ""),
    deterministic_species_ids = coalesce(deterministic_species_ids, ""),
    deterministic_primary_countries = coalesce(deterministic_primary_countries, ""),
    deterministic_primary_iso3c = coalesce(deterministic_primary_iso3c, ""),
    species_review_required = coalesce(species_review_required, FALSE) & !species_reused,
    geography_review_required = coalesce(geography_review_required, FALSE) & !geography_reused
  )

# Only unresolved dimensions enter adjudication. Screening uncertainty is not an
# annotation error: it simply travels with the record to the later combined gate.
queue <- records |>
  select(record_sequence, record_id, title, abstract, screening_decision) |>
  inner_join(state |> filter(species_review_required | geography_review_required), by="record_id")
if (nrow(geo$ranking)) {
  candidates <- geo$ranking |>
    group_by(record_id) |>
    summarise(geography_candidates=paste(unique(paste0(country_name," [",iso3c,"]; tier ",best_tier)),collapse="; "),.groups="drop")
  queue <- queue |> left_join(candidates, by="record_id")
} else queue$geography_candidates <- ""
queue$geography_candidates <- coalesce(queue$geography_candidates, "")
write_csv(queue, path(output_dir, "annotation_adjudication_queue.csv"), na = "")

openai_annotation_model <- function(system_prompt, user_prompt, schema,
                                     api_key=Sys.getenv("OPENAI_API_KEY"), model_name=model) {
  body <- list(model=model_name,store=FALSE,reasoning=list(effort="low"),
               input=list(
                 list(role="system",content=list(list(type="input_text",text=system_prompt))),
                 list(role="user",content=list(list(type="input_text",text=user_prompt)))
               ),
               text=list(verbosity="low",format=list(type="json_schema",
                 name="salmon_annotation_adjudication",strict=TRUE,schema=schema)))
  httr2::request("https://api.openai.com/v1/responses") |>
    httr2::req_auth_bearer_token(api_key) |>
    httr2::req_body_json(body,auto_unbox=TRUE) |>
    httr2::req_timeout(120) |>
    httr2::req_retry(max_tries=4,backoff=~2^.x) |>
    httr2::req_perform() |>
    httr2::resp_body_json() |>
    extract_openai_output_text() |>
    jsonlite::fromJSON(simplifyVector=TRUE)
}

if (llm_mode == "new-only" && nrow(queue)) {
  if (max_llm_records > 0L && nrow(queue) > max_llm_records) {
    stop(sprintf("Adjudication queue has %d records, above safety cap %d; no API calls made.", nrow(queue), max_llm_records), call. = FALSE)
  }
  adjudication <- adjudicate_annotation_queue(queue, openai_annotation_model, progress=TRUE)
  if (any(adjudication$llm_failed %in% TRUE)) stop("Technical LLM adjudication failure(s) occurred", call. = FALSE)
} else adjudication <- tibble()
write_csv(adjudication, path(output_dir, "annotation_adjudication.csv"), na = "")

state_final <- state
if (nrow(adjudication)) state_final <- left_join(state_final, adjudication, by="record_id")
for (nm in c("species_decision","llm_species","species_reason","geography_decision","llm_primary_country_iso3c","geography_reason")) {
  if (!nm %in% names(state_final)) state_final[[nm]] <- ""
  state_final[[nm]] <- clean(state_final[[nm]])
}

state_final <- state_final |>
  mutate(
    final_species = case_when(
      species_reused ~ master_species,
      species_review_required & species_decision %in% c("ACCEPT","CHANGE") & nzchar(llm_species) ~ llm_species,
      !species_review_required & nzchar(deterministic_species) ~ deterministic_species,
      TRUE ~ ""
    ),
    species_provenance = case_when(
      species_reused ~ "historical_master",
      species_review_required & species_decision %in% c("ACCEPT","CHANGE") & nzchar(llm_species) ~ "workflow05_llm_new_only",
      !species_review_required & nzchar(deterministic_species) ~ "workflow05_deterministic",
      TRUE ~ "workflow05_unresolved"
    ),
    final_primary_country_iso3c = case_when(
      geography_reused ~ master_primary_country_iso3c,
      geography_review_required & geography_decision %in% c("ACCEPT","CHANGE") & nzchar(llm_primary_country_iso3c) ~ llm_primary_country_iso3c,
      !geography_review_required & nzchar(deterministic_primary_iso3c) ~ deterministic_primary_iso3c,
      TRUE ~ ""
    ),
    final_primary_countries = case_when(
      geography_reused ~ master_primary_countries,
      !geography_review_required & nzchar(deterministic_primary_countries) ~ deterministic_primary_countries,
      TRUE ~ ""
    ),
    geography_provenance = case_when(
      geography_reused ~ "historical_master",
      geography_review_required & geography_decision %in% c("ACCEPT","CHANGE") & nzchar(llm_primary_country_iso3c) ~ "workflow05_llm_new_only",
      !geography_review_required & nzchar(deterministic_primary_iso3c) ~ "workflow05_deterministic",
      TRUE ~ "workflow05_unresolved"
    ),
    annotation_review_required = species_provenance == "workflow05_unresolved" |
                                 geography_provenance == "workflow05_unresolved"
  )

state_map <- split(state_final, state_final$record_id)
for (i in eligible_idx) {
  r <- canonical_records[[i]]
  lid <- lens_id_of(r)
  s <- state_map[[lid]]
  if (is.null(s) || nrow(s) != 1L) stop("Missing Workflow 05 state for Lens ID: ", lid, call. = FALSE)
  a <- r$annotations %||% list()
  a$species_geography <- list(
    workflow="workflow_05_species_geography",
    completed_at=now_utc(),
    screening_decision=screen_decision(r),
    species=list(
      value=s$final_species[[1]],
      deterministic=s$deterministic_species[[1]],
      deterministic_ids=s$deterministic_species_ids[[1]],
      provenance=s$species_provenance[[1]],
      review_required=isTRUE(s$species_provenance[[1]] == "workflow05_unresolved")
    ),
    geography=list(
      primary_countries=s$final_primary_countries[[1]],
      primary_iso3c=s$final_primary_country_iso3c[[1]],
      deterministic_countries=s$deterministic_primary_countries[[1]],
      deterministic_iso3c=s$deterministic_primary_iso3c[[1]],
      provenance=s$geography_provenance[[1]],
      review_required=isTRUE(s$geography_provenance[[1]] == "workflow05_unresolved")
    ),
    review_required=isTRUE(s$annotation_review_required[[1]])
  )
  r$annotations <- a
  canonical_records[[i]] <- r
}

output_jsonl <- path(output_dir, "records.jsonl")
con <- file(output_jsonl, "wt", encoding="UTF-8")
on.exit(close(con), add=TRUE)
for (r in canonical_records) writeLines(toJSON(r,auto_unbox=TRUE,null="null",na="null",digits=NA),con)
close(con)

review <- records |>
  select(record_id,lens_id,doi,title,screening_decision) |>
  left_join(state_final |> select(record_id,final_species,final_primary_country_iso3c,species_provenance,geography_provenance,annotation_review_required),by="record_id") |>
  filter(screening_decision == "uncertain" | annotation_review_required)
write_csv(review, path(output_dir,"workflow05_review_queue.csv"),na="")

summary <- list(
  workflow="workflow_05_species_geography",
  completed_at=now_utc(),
  input=input_path,
  output=output_jsonl,
  total_canonical_records=length(canonical_records),
  screening_include=as.integer(screen_counts[["include"]]),
  screening_uncertain=as.integer(screen_counts[["uncertain"]]),
  screening_exclude=as.integer(screen_counts[["exclude"]]),
  records_forwarded_to_annotation=nrow(records),
  master_matches=sum(reuse$master_match),
  species_reused_from_master=sum(reuse$species_reused),
  geography_reused_from_master=sum(reuse$geography_reused),
  species_deterministic_records=nrow(species_records),
  geography_deterministic_records=nrow(geo_records),
  annotation_adjudication_queue_records=nrow(queue),
  llm_mode=llm_mode,
  llm_calls_attempted=if (llm_mode=="new-only") nrow(queue) else 0L,
  screening_uncertain_carried_forward=sum(records$screening_decision=="uncertain"),
  annotation_unresolved=sum(state_final$annotation_review_required),
  combined_review_candidates=nrow(review),
  substantive_uncertainty_deferred_to_post_topic_gate=TRUE
)
writeLines(toJSON(summary,auto_unbox=TRUE,pretty=TRUE,na="null"),path(output_dir,"workflow05_summary.json"))

message(sprintf(
  "Workflow 05 complete: annotated=%d; screening uncertain carried=%d; annotation unresolved=%d; LLM calls=%d. Substantive review deferred until after topic classification.",
  nrow(records),sum(records$screening_decision=="uncertain"),sum(state_final$annotation_review_required),summary$llm_calls_attempted
))
