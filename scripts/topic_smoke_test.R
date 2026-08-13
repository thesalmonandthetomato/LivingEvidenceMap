# Controlled topic-classification smoke test.
# This is intentionally one API call only. Full topic classification remains
# the final production stage but is not rerun for the current Lens refresh.

source("scripts/00_setup.R")
source("R/topic_classification.R")

out <- here::here("data", "updates", "2026-08-13_lens")
input_file <- fs::path(out, "records_after_species_geography_adjudication.csv")

if (!file.exists(input_file)) stop("Expected annotated Lens output is missing: ", input_file)
records <- readr::read_csv(input_file, show_col_types = FALSE)
if (!nrow(records)) stop("No retained records are available for the topic smoke test.")

# A deliberately small representative ontology is sufficient to test the
# production classifier's API contract without paying for full topic reruns.
smoke_ontology <- tibble::tribble(
  ~broad_topic, ~subtopic, ~feature, ~component, ~supporting_terms,
  "Pathology", "Impacts", "General", "General", "mortality; morbidity; disease severity",
  "Feed", "Additives", "General", "General", "probiotic; amino acid; functional ingredient"
)

record <- records[1, ]
title <- dplyr::coalesce(record$title[[1]], "")
abstract <- dplyr::coalesce(record$abstract[[1]], "")

if (!nzchar(Sys.getenv("OPENAI_API_KEY"))) {
  stop("OPENAI_API_KEY is required for the topic smoke test.")
}

result <- classify_topic_hierarchy_single_call(
  title = title,
  abstract = abstract,
  ontology = smoke_ontology,
  model = "gpt-5-mini"
)

readr::write_csv(result, fs::path(out, "topic_smoke_test.csv"), na = "")

message("Topic smoke test passed: one API call completed and returned schema-valid topic assignments.")
