testthat::test_that("species detection prefers longest overlapping terms", {
  dictionary <- data.frame(
    species_id = c("ATL_SALMO", "UNSPEC_SALMON"),
    preferred_name = c("Atlantic salmon", "Unspecified farmed salmon"),
    scientific_name = c("Salmo salar", NA),
    synonym = c("Atlantic salmon", "salmon"),
    synonym_type = c("common", "generic"),
    is_farmed_candidate = c(TRUE, TRUE),
    default_group = c("farmed_salmon", "farmed_salmon"),
    stringsAsFactors = FALSE
  )
  hits <- detect_species_mentions("Atlantic salmon farming", "", dictionary)
  testthat::expect_true(any(hits$matched_term == "Atlantic salmon"))
  testthat::expect_false(any(hits$matched_term == "salmon" & hits$source == "title"))
})

testthat::test_that("specific farmed salmon suppresses generic assignment", {
  mentions <- data.frame(
    species_id = c("UNSPEC_SALMON", "ATL_SALMO"),
    preferred_name = c("Unspecified farmed salmon", "Atlantic salmon"),
    scientific_name = c(NA, "Salmo salar"),
    matched_term = c("salmon", "Atlantic salmon"),
    synonym_type = c("generic", "common"), source = c("abstract", "abstract"),
    match_start = c(1L, 20L), match_end = c(6L, 34L),
    is_farmed_candidate = c(TRUE, TRUE), default_group = c("farmed_salmon", "farmed_salmon"),
    stringsAsFactors = FALSE
  )
  result <- assign_farmed_species(mentions)
  testthat::expect_equal(result$farmed_species, "Atlantic salmon")
  testthat::expect_equal(nrow(result), 1L)
})

testthat::test_that("target validation rejects duplicated identifiers", {
  records <- data.frame(record_sequence = c(1L, 2L), record_id = c("A", "A"), title = c("a", "b"), abstract = c("a", "b"))
  testthat::expect_error(validate_target_records(records, "TEST"), "record_id")
})
