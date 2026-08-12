testthat::test_that("adjudication queue contains only flagged records", {
  records <- data.frame(record_sequence = 1:3, record_id = c("A","B","C"), title = c("A","B","C"), abstract = c("","", ""))
  species <- data.frame(record_id = "A", farmed_species = "Atlantic salmon", farmed_species_id = "SAL_ATL", assignment_reason = "deterministic", non_target_species = NA_character_)
  geo <- data.frame(record_id = "B", review_required = TRUE, review_reason = "tie", primary_countries = NA_character_, primary_iso3c = NA_character_)
  rank <- data.frame(record_id = "B", country_name = "Norway", iso3c = "NOR", best_tier = 2L)
  q <- build_annotation_adjudication_queue(records, species, geo, rank)
  testthat::expect_setequal(q$record_id, c("A", "B"))
})

testthat::test_that("unflagged dimensions are explicitly protected in prompt", {
  row <- data.frame(record_id = "A", species_review_required = FALSE, geography_review_required = TRUE, title = "Study in Norway", abstract = "", geography_review_reason = "tie", deterministic_primary_countries = NA_character_, deterministic_primary_iso3c = NA_character_, geography_candidates = "Norway [NOR]; tier 2")
  prompt <- make_annotation_adjudication_prompt(row)
  testthat::expect_match(prompt, "SPECIES NOT FLAGGED: do not change", fixed = TRUE)
  testthat::expect_match(prompt, "GEOGRAPHY FLAGGED:", fixed = TRUE)
})

testthat::test_that("model function is injectable and errors become unresolved", {
  q <- data.frame(record_id = "A", species_review_required = FALSE, geography_review_required = TRUE, title = "Study", abstract = "")
  result <- adjudicate_annotation_queue(q, function(...) stop("mock failure"))
  testthat::expect_true(result$llm_failed)
  testthat::expect_equal(result$geography_decision, "UNRESOLVED")
})

testthat::test_that("successful mock adjudication is preserved", {
  q <- data.frame(record_id = "A", species_review_required = FALSE, geography_review_required = TRUE, title = "Study in Norway", abstract = "")
  result <- adjudicate_annotation_queue(q, function(system, user, schema) list(species_decision = "NOT_REVIEWED", species = "NONE", species_reason = "Not flagged", geography_decision = "ACCEPT", primary_country_iso3c = "NOR", geography_reason = "Study location"))
  testthat::expect_false(result$llm_failed)
  testthat::expect_equal(result$llm_primary_country_iso3c, "NOR")
})
