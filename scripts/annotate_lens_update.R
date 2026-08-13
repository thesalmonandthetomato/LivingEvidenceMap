# Continue a screened Lens update through species/geography annotation and LLM adjudication.
# Topic classification is the final pipeline stage and is handled separately.

source("scripts/setup_pipeline.R")
source("R/species_detect.R")
source("R/species_filter.R")
source("R/species_assign.R")
source("R/species_annotation.R")
source("R/geography_detect.R")
source("R/geography_primary_country.R")
source("R/llm_adjudication.R")

out <- here::here("data", "updates", "2026-08-13_lens")
records <- readr::read_csv(fs::path(out, "records_retained_for_annotation.csv"), show_col_types = FALSE)
species_dictionary <- readr::read_csv(here::here("config", "species_dictionary.csv"), show_col_types = FALSE)
gazetteer <- readr::read_csv(here::here("config", "global_country_gazetteer_v3.csv"), show_col_types = FALSE)

species <- annotate_species(records, species_dictionary)
readr::write_csv(species$species_mentions, fs::path(out, "species_mentions.csv"), na = "")
readr::write_csv(species$species_assignments, fs::path(out, "species_assignments.csv"), na = "")
readr::write_csv(species$failures, fs::path(out, "species_annotation_failures.csv"), na = "")

geo_mentions <- detect_geography_mentions(records, gazetteer)
geo <- assign_primary_country(geo_mentions)
readr::write_csv(geo_mentions, fs::path(out, "geography_mentions.csv"), na = "")
readr::write_csv(geo$ranking, fs::path(out, "geography_ranking.csv"), na = "")
readr::write_csv(geo$assignments, fs::path(out, "geography_assignments.csv"), na = "")
readr::write_csv(geo$summary, fs::path(out, "geography_summary.csv"), na = "")
readr::write_csv(geo$review_queue, fs::path(out, "geography_review_queue.csv"), na = "")

# Adjudication happens after annotation, not before it.
queue <- build_annotation_adjudication_queue(records, species$species_assignments, geo$summary, geo$ranking)
readr::write_csv(queue, fs::path(out, "annotation_adjudication_queue.csv"), na = "")

openai_annotation_model <- function(system_prompt, user_prompt, schema,
                                     api_key = Sys.getenv("OPENAI_API_KEY"), model = "gpt-5-mini") {
  if (!nzchar(api_key)) stop("OPENAI_API_KEY was not found.")
  body <- list(model = model, store = FALSE, reasoning = list(effort = "low"),
               input = list(
                 list(role = "system", content = list(list(type = "input_text", text = system_prompt))),
                 list(role = "user", content = list(list(type = "input_text", text = user_prompt)))
               ),
               text = list(verbosity = "low", format = list(type = "json_schema",
                 name = "salmon_annotation_adjudication", strict = TRUE, schema = schema)))
  httr2::request("https://api.openai.com/v1/responses") |>
    httr2::req_auth_bearer_token(api_key) |>
    httr2::req_body_json(body, auto_unbox = TRUE) |>
    httr2::req_timeout(120) |>
    httr2::req_retry(max_tries = 4, backoff = ~ 2^.x) |>
    httr2::req_perform() |>
    httr2::resp_body_json() |>
    extract_openai_output_text() |>
    jsonlite::fromJSON(simplifyVector = TRUE)
}

if (nrow(queue)) {
  if (!nzchar(Sys.getenv("OPENAI_API_KEY"))) stop("OPENAI_API_KEY is required for annotation adjudication.")
  adjudication <- adjudicate_annotation_queue(queue, openai_annotation_model)
} else {
  adjudication <- tibble::tibble()
}

readr::write_csv(adjudication, fs::path(out, "annotation_adjudication.csv"), na = "")

final <- records |>
  dplyr::left_join(species$species_assignments |>
                     dplyr::group_by(record_id) |>
                     dplyr::summarise(
                       deterministic_species = paste(sort(unique(stats::na.omit(farmed_species))), collapse = "; "),
                       deterministic_species_ids = paste(sort(unique(stats::na.omit(farmed_species_id))), collapse = "; "),
                       species_review_required = any(review_required), .groups = "drop"), by = "record_id") |>
  dplyr::left_join(geo$summary |>
                     dplyr::select(record_id, deterministic_primary_countries = primary_countries,
                                   deterministic_primary_iso3c = primary_iso3c,
                                   geography_review_required = review_required), by = "record_id") |>
  dplyr::left_join(adjudication, by = "record_id")

readr::write_csv(final, fs::path(out, "records_after_species_geography_adjudication.csv"), na = "")
message("Lens annotation completed through species/geography adjudication.")
