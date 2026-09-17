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
# CONTRACT
#   Input: canonical JSONL produced by Workflow 04.
#   Scope: canonical/unique, publication-eligible records with screening.decision == include.
#   Output: the same canonical JSONL structure, with Workflow 05 annotations added.
#
# COST CONTROL
#   1. Reuse existing species/geography from the production master wherever a
#      unique Lens ID, DOI or normalised-title match is available.
#   2. Run local deterministic species/geography annotation only for dimensions
#      not recovered from the master.
#   3. Never send a master-reused dimension to the LLM.
#   4. --llm-mode=off guarantees zero API calls and emits a review queue.
#   5. --llm-mode=new-only sends only genuinely unresolved, non-reused dimensions.

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

if (is.null(input_path)) stop("--input canonical JSONL is required", call. = FALSE)
if (!file.exists(input_path)) stop("Canonical input does not exist: ", input_path, call. = FALSE)
if (!file.exists(master_path)) stop("Master CSV does not exist: ", master_path, call. = FALSE)
if (!llm_mode %in% c("off", "new-only")) stop("--llm-mode must be off or new-only", call. = FALSE)
if (is.na(max_llm_records) || max_llm_records < 0L) stop("--max-llm-records must be >= 0", call. = FALSE)
if (llm_mode == "new-only" && !nzchar(Sys.getenv("OPENAI_API_KEY"))) stop("OPENAI_API_KEY is required for --llm-mode=new-only", call. = FALSE)

dir_create(output_dir, recurse = TRUE)
now_utc <- function() format(Sys.time(), tz = "UTC", format = "%Y-%m-%dT%H:%M:%SZ")
`%||%` <- function(x, y) if (is.null(x)) y else x
clean <- function(x) {
  x <- as.character(x %||% "")
  x[is.na(x)] <- ""
  trimws(x)
}
textify <- function(x) {
  if (is.null(x)) return("")
  if (is.atomic(x)) return(paste(clean(x)[nzchar(clean(x))], collapse = "; "))
  if (is.list(x)) return(paste(Filter(nzchar, vapply(x, textify, character(1))), collapse = "; "))
  clean(x)
}
first_nonempty <- function(...) {
  for (x in list(...)) {
    z <- textify(x)
    if (nzchar(trimws(z))) return(trimws(z))
  }
  ""
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
    tryCatch(fromJSON(lines[[i]], simplifyVector = FALSE), error = function(e) {
      stop(sprintf("Invalid JSONL at line %d: %s", i, conditionMessage(e)), call. = FALSE)
    })
  })
}
write_jsonl <- function(records, path) {
  dir_create(dirname(path), recurse = TRUE)
  con <- file(path, "w", encoding = "UTF-8")
  on.exit(close(con), add = TRUE)
  for (r in records) writeLines(toJSON(r, auto_unbox = TRUE, null = "null", na = "null", digits = NA), con)
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

message("Workflow 05: reading canonical JSONL from Workflow 04.")
canonical_records <- read_jsonl(input_path)
master <- read_csv(master_path, show_col_types = FALSE, progress = FALSE)
if (!length(canonical_records)) stop("Canonical input contains no records", call. = FALSE)

record_view <- function(r, seq) {
  id <- r$identity %||% list()
  can <- r$canonical %||% list()
  raw <- (r$lens %||% list())$raw_payload %||% list()
  dedup <- r$deduplication %||% list()
  notices <- r$notices
  screening <- r$screening %||% list()
  publication_ok <- if (is.null(notices)) TRUE else isTRUE(notices$record_downstream_eligible %||% notices$downstream_eligible %||% TRUE)
  dedup_ok <- clean(dedup$status) %in% c("unique", "canonical")
  included <- identical(clean(screening$decision), "include")
  list(
    record_sequence = seq,
    record_id = first_nonempty(id$lens_id, can$lens_id, raw$lens_id, id$doi, can$doi, raw$doi),
    lens_id = first_nonempty(id$lens_id, can$lens_id, raw$lens_id),
    doi = first_nonempty(id$doi, can$doi, raw$doi),
    title = first_nonempty(can$title, raw$title),
    abstract = first_nonempty(can$abstract, raw$abstract),
    workflow05_target = dedup_ok && publication_ok && included,
    screening_decision = clean(screening$decision),
    deduplication_status = clean(dedup$status),
    publication_eligible = publication_ok
  )
}
views <- lapply(seq_along(canonical_records), function(i) record_view(canonical_records[[i]], i))
flat <- bind_rows(views)
if (any(!nzchar(flat$record_id))) stop("At least one canonical record has no usable identity", call. = FALSE)
targets <- flat |> filter(workflow05_target)
message(sprintf("Workflow 05: canonical records=%d; annotation targets=%d.", nrow(flat), nrow(targets)))

# Production-master reuse. We only treat non-blank values as reusable evidence.
master$.lens_key <- tolower(first_col(master, c("lens_id", "Lens ID", "LensID", "record_id")))
master$.doi_key <- normalise_doi(first_col(master, c("doi", "DOI", "doi_id")))
master$.title_key <- normalise_title(first_col(master, c("title", "Title", "document_title", "Document Title")))
master$.species_value <- first_col(master, c(
  "final_species", "species_final", "final_farmed_species", "adjudicated_species",
  "farmed_species", "species", "Species", "llm_species", "deterministic_species"
))
master$.geo_iso3c <- first_col(master, c(
  "final_primary_country_iso3c", "primary_country_iso3c_final", "adjudicated_primary_country_iso3c",
  "primary_iso3c", "country_iso3c", "iso3c", "llm_primary_country_iso3c", "deterministic_primary_iso3c"
))
master$.geo_country <- first_col(master, c(
  "final_primary_country", "final_primary_countries", "primary_country_final", "primary_countries",
  "country", "Country", "geography", "Geography", "deterministic_primary_countries"
))
unique_index <- function(values) {
  ok <- nzchar(values)
  tab <- table(values[ok])
  vals <- names(tab)[tab == 1L]
  idx <- which(ok & values %in% vals)
  setNames(idx, values[idx])
}
lens_index <- unique_index(master$.lens_key)
doi_index <- unique_index(master$.doi_key)
title_index <- unique_index(master$.title_key)

match_master <- function(lens, doi, title) {
  lk <- tolower(clean(lens)); dk <- normalise_doi(doi); tk <- normalise_title(title)
  if (nzchar(lk) && lk %in% names(lens_index)) return(unname(lens_index[[lk]]))
  if (nzchar(dk) && dk %in% names(doi_index)) return(unname(doi_index[[dk]]))
  if (nzchar(tk) && tk %in% names(title_index)) return(unname(title_index[[tk]]))
  NA_integer_
}
master_rows <- mapply(match_master, targets$lens_id, targets$doi, targets$title)
reuse <- targets |>
  transmute(
    record_sequence, record_id,
    master_match_row = master_rows,
    master_species = ifelse(is.na(master_rows), "", master$.species_value[master_rows]),
    master_primary_country_iso3c = ifelse(is.na(master_rows), "", master$.geo_iso3c[master_rows]),
    master_primary_countries = ifelse(is.na(master_rows), "", master$.geo_country[master_rows])
  ) |>
  mutate(
    master_species = clean(master_species),
    master_primary_country_iso3c = clean(master_primary_country_iso3c),
    master_primary_countries = clean(master_primary_countries),
    master_match = !is.na(master_match_row),
    species_reused = nzchar(master_species),
    geography_reused = nzchar(master_primary_country_iso3c) | nzchar(master_primary_countries)
  )
write_csv(reuse, path(output_dir, "master_annotation_reuse.csv"), na = "")
message(sprintf("Workflow 05: master matches=%d; species reused=%d; geography reused=%d.", sum(reuse$master_match), sum(reuse$species_reused), sum(reuse$geography_reused)))

species_records <- targets |>
  inner_join(reuse |> filter(!species_reused) |> select(record_id), by = "record_id") |>
  select(record_sequence, record_id, title, abstract)
geo_records <- targets |>
  inner_join(reuse |> filter(!geography_reused) |> select(record_id), by = "record_id") |>
  select(record_sequence, record_id, title, abstract)

species_dictionary <- read_csv(here("config", "species_dictionary.csv"), show_col_types = FALSE, progress = FALSE)
gazetteer <- read_csv(here("config", "global_country_gazetteer_v3.csv"), show_col_types = FALSE, progress = FALSE)

message(sprintf("Workflow 05: local species annotation required for %d targets.", nrow(species_records)))
species <- if (nrow(species_records)) annotate_species(species_records, species_dictionary, progress = TRUE) else list(species_mentions = tibble(), species_assignments = tibble(), failures = tibble())
write_csv(species$species_mentions, path(output_dir, "species_mentions.csv"), na = "")
write_csv(species$species_assignments, path(output_dir, "species_assignments.csv"), na = "")
write_csv(species$failures, path(output_dir, "species_annotation_failures.csv"), na = "")
if (nrow(species$failures)) stop("Species annotation failures present; refusing to continue", call. = FALSE)

message(sprintf("Workflow 05: local geography annotation required for %d targets.", nrow(geo_records)))
if (nrow(geo_records)) {
  geo_mentions <- detect_geography_mentions(geo_records, gazetteer, progress = TRUE)
  geo <- if (nrow(geo_mentions)) assign_primary_country(geo_mentions) else list(ranking=tibble(),assignments=tibble(),summary=tibble(),review_queue=tibble())
} else {
  geo_mentions <- tibble(); geo <- list(ranking=tibble(),assignments=tibble(),summary=tibble(),review_queue=tibble())
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
} else sp <- tibble(record_id=character(),deterministic_species=character(),deterministic_species_ids=character(),species_review_required=logical(),species_reasons=character(),non_target_species=character())

if (nrow(geo$summary)) {
  gs <- geo$summary |>
    transmute(record_id=as.character(record_id), deterministic_primary_countries=clean(primary_countries), deterministic_primary_iso3c=clean(primary_iso3c), geography_review_required=review_required %in% TRUE, geography_review_reason=clean(review_reason))
} else gs <- tibble(record_id=character(),deterministic_primary_countries=character(),deterministic_primary_iso3c=character(),geography_review_required=logical(),geography_review_reason=character())

state <- reuse |>
  left_join(sp, by="record_id") |>
  left_join(gs, by="record_id") |>
  mutate(
    deterministic_species=coalesce(deterministic_species,""),
    deterministic_species_ids=coalesce(deterministic_species_ids,""),
    deterministic_primary_countries=coalesce(deterministic_primary_countries,""),
    deterministic_primary_iso3c=coalesce(deterministic_primary_iso3c,""),
    species_reasons=coalesce(species_reasons,""),
    non_target_species=coalesce(non_target_species,""),
    geography_review_reason=coalesce(geography_review_reason,""),
    species_review_required=coalesce(species_review_required,FALSE) & !species_reused,
    geography_review_required=coalesce(geography_review_required,FALSE) & !geography_reused
  )

# Only genuinely unresolved dimensions enter the adjudication queue.
queue <- targets |>
  select(record_sequence,record_id,title,abstract) |>
  inner_join(state |> filter(species_review_required | geography_review_required), by="record_id")
if (nrow(geo$ranking)) {
  candidates <- geo$ranking |> group_by(record_id) |> summarise(geography_candidates=paste(unique(paste0(country_name," [",iso3c,"]; tier ",best_tier)),collapse="; "),.groups="drop")
  queue <- queue |> left_join(candidates,by="record_id")
}
if (!"geography_candidates" %in% names(queue)) queue$geography_candidates <- ""
queue$geography_candidates <- coalesce(queue$geography_candidates, "")
write_csv(queue, path(output_dir,"annotation_adjudication_queue.csv"), na="")
message(sprintf("Workflow 05: unresolved adjudication queue=%d records.", nrow(queue)))

openai_annotation_model <- function(system_prompt,user_prompt,schema,api_key=Sys.getenv("OPENAI_API_KEY"),model_name=model) {
  body <- list(model=model_name,store=FALSE,reasoning=list(effort="low"),input=list(
    list(role="system",content=list(list(type="input_text",text=system_prompt))),
    list(role="user",content=list(list(type="input_text",text=user_prompt)))
  ),text=list(verbosity="low",format=list(type="json_schema",name="salmon_annotation_adjudication",strict=TRUE,schema=schema)))
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

if (llm_mode=="new-only" && nrow(queue)) {
  if (max_llm_records>0L && nrow(queue)>max_llm_records) stop(sprintf("Queue=%d exceeds --max-llm-records=%d; refusing API calls",nrow(queue),max_llm_records),call.=FALSE)
  adjudication <- adjudicate_annotation_queue(queue,openai_annotation_model,progress=TRUE)
} else adjudication <- tibble()
write_csv(adjudication,path(output_dir,"annotation_adjudication.csv"),na="")

if (nrow(adjudication)) state <- state |> left_join(adjudication,by="record_id")
for (nm in c("species_decision","llm_species","species_reason","geography_decision","llm_primary_country_iso3c","geography_reason","llm_failed","llm_error")) {
  if (!nm %in% names(state)) state[[nm]] <- if (nm=="llm_failed") FALSE else ""
}
state <- state |>
  mutate(
    species_decision=clean(species_decision), llm_species=clean(llm_species), geography_decision=clean(geography_decision), llm_primary_country_iso3c=clean(llm_primary_country_iso3c),
    llm_failed=coalesce(as.logical(llm_failed),FALSE),
    final_species=case_when(
      species_reused ~ master_species,
      species_review_required & species_decision %in% c("ACCEPT","CHANGE") & nzchar(llm_species) ~ llm_species,
      !species_review_required & nzchar(deterministic_species) ~ deterministic_species,
      TRUE ~ ""
    ),
    species_provenance=case_when(
      species_reused ~ "historical_master",
      species_review_required & species_decision %in% c("ACCEPT","CHANGE") & nzchar(llm_species) ~ "workflow05_llm_new_only",
      !species_review_required & nzchar(deterministic_species) ~ "workflow05_deterministic",
      TRUE ~ "workflow05_unresolved"
    ),
    final_primary_country_iso3c=case_when(
      geography_reused ~ master_primary_country_iso3c,
      geography_review_required & geography_decision %in% c("ACCEPT","CHANGE") & nzchar(llm_primary_country_iso3c) ~ llm_primary_country_iso3c,
      !geography_review_required ~ deterministic_primary_iso3c,
      TRUE ~ ""
    ),
    final_primary_countries=case_when(
      geography_reused ~ master_primary_countries,
      !geography_review_required ~ deterministic_primary_countries,
      TRUE ~ ""
    ),
    geography_provenance=case_when(
      geography_reused ~ "historical_master",
      geography_review_required & geography_decision %in% c("ACCEPT","CHANGE") & nzchar(llm_primary_country_iso3c) ~ "workflow05_llm_new_only",
      !geography_review_required & (nzchar(deterministic_primary_iso3c)|nzchar(deterministic_primary_countries)) ~ "workflow05_deterministic",
      !geography_review_required ~ "workflow05_no_country_detected",
      TRUE ~ "workflow05_unresolved"
    ),
    workflow05_review_required = species_provenance=="workflow05_unresolved" | geography_provenance=="workflow05_unresolved" | llm_failed
  )

state_by_seq <- setNames(seq_len(nrow(state)), as.character(state$record_sequence))
for (i in seq_along(canonical_records)) {
  k <- as.character(i)
  if (!k %in% names(state_by_seq)) next
  s <- state[[state_by_seq[[k]], , drop=FALSE]]
  r <- canonical_records[[i]]
  ann <- r$annotations %||% list()
  ann$species <- list(
    value=s$final_species[[1]],
    deterministic_value=s$deterministic_species[[1]],
    deterministic_ids=s$deterministic_species_ids[[1]],
    provenance=s$species_provenance[[1]],
    review_required=isTRUE(s$species_provenance[[1]]=="workflow05_unresolved")
  )
  ann$geography <- list(
    primary_countries=s$final_primary_countries[[1]],
    primary_iso3c=s$final_primary_country_iso3c[[1]],
    deterministic_primary_countries=s$deterministic_primary_countries[[1]],
    deterministic_primary_iso3c=s$deterministic_primary_iso3c[[1]],
    provenance=s$geography_provenance[[1]],
    review_required=isTRUE(s$geography_provenance[[1]]=="workflow05_unresolved")
  )
  ann$workflow05 <- list(
    workflow="workflow_05_species_geography",
    completed_at=now_utc(),
    master_reuse=isTRUE(s$master_match[[1]]),
    llm_mode=llm_mode,
    review_required=isTRUE(s$workflow05_review_required[[1]])
  )
  r$annotations <- ann
  canonical_records[[i]] <- r
}

output_jsonl <- path(output_dir,"records.jsonl")
write_jsonl(canonical_records,output_jsonl)
review <- state |> filter(workflow05_review_required) |> left_join(targets |> select(record_sequence,record_id,title,abstract),by=c("record_sequence","record_id"))
write_csv(review,path(output_dir,"workflow05_human_review_queue.csv"),na="")

summary <- list(
  workflow="workflow_05_species_geography",
  input=input_path,
  output=output_jsonl,
  completed_at=now_utc(),
  canonical_records=length(canonical_records),
  annotation_targets=nrow(targets),
  expected_workflow04_includes=16068,
  target_count_matches_workflow04_completion=(nrow(targets)==16068),
  master_matches=sum(reuse$master_match),
  species_reused_from_master=sum(reuse$species_reused),
  geography_reused_from_master=sum(reuse$geography_reused),
  species_deterministic_records=nrow(species_records),
  geography_deterministic_records=nrow(geo_records),
  adjudication_queue_records=nrow(queue),
  llm_mode=llm_mode,
  llm_calls_attempted=if (llm_mode=="new-only") nrow(queue) else 0L,
  llm_failures=if (nrow(adjudication)) sum(adjudication$llm_failed %in% TRUE) else 0L,
  human_review_records=nrow(review),
  complete=nrow(review)==0L
)
writeLines(toJSON(summary,auto_unbox=TRUE,pretty=TRUE,na="null"),path(output_dir,"workflow05_summary.json"))
if (nrow(targets)!=16068) warning(sprintf("Workflow 04 completed with 16068 includes, but Workflow 05 found %d targets",nrow(targets)))
message(sprintf("Workflow 05 finished: targets=%d; species master=%d; geography master=%d; adjudication queue=%d; human review=%d; LLM calls=%d.",nrow(targets),sum(reuse$species_reused),sum(reuse$geography_reused),nrow(queue),nrow(review),if(llm_mode=="new-only")nrow(queue) else 0L))
