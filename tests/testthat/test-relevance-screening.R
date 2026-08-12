testthat::test_that("screening keys are deterministic and normalised", {
  records <- tibble::tibble(
    record_id = "r1",
    title = "Atlantic Salmon & Health",
    abstract = "A short abstract.",
    doi = "https://doi.org/10.1234/ABC.1",
    authors = "Müller, A | Smith, B",
    year = 2024
  )

  keyed <- add_screening_keys(records)

  testthat::expect_equal(keyed$title_key, "atlantic salmon health")
  testthat::expect_equal(keyed$doi_key, "10.1234/abc.1")
  testthat::expect_equal(keyed$first_author_key, "muller a")
  testthat::expect_true(keyed$has_abstract)
  testthat::expect_true(grepl("TITLE_TITLE", keyed$screening_text, fixed = TRUE))
})

testthat::test_that("label conflicts are detected by title and DOI", {
  records <- tibble::tibble(
    record_id = c("a", "b", "c"),
    title = c("Same title", "Same title", "Different title"),
    abstract = c("x", "y", "z"),
    doi = c("10.1/example", "10.1/example", "10.1/other"),
    authors = c("A", "B", "C"),
    eligibility = c(1L, 0L, 1L),
    title_key = normalise_screening_title(title),
    doi_key = normalise_screening_doi(doi)
  )

  conflicts <- find_label_conflicts(records)

  testthat::expect_true(any(conflicts$conflict_basis == "exact normalised title"))
  testthat::expect_true(any(conflicts$conflict_basis == "exact normalised DOI"))
})

testthat::test_that("classification metrics calculate sensitivity and precision", {
  metrics <- classification_metrics(
    truth = c(1L, 1L, 0L, 0L),
    probability = c(0.9, 0.2, 0.8, 0.1),
    threshold = 0.5
  )

  testthat::expect_equal(metrics$true_positive, 1L)
  testthat::expect_equal(metrics$false_positive, 1L)
  testthat::expect_equal(metrics$sensitivity, 0.5)
  testthat::expect_equal(metrics$precision, 0.5)
})

testthat::test_that("screening decisions preserve the review band", {
  thresholds <- list(exclude_threshold = 0.2, include_threshold = 0.8)

  testthat::expect_equal(
    assign_screening_decision(c(0.1, 0.5, 0.9), thresholds),
    c("automatic_exclude", "review", "automatic_retain")
  )
})

testthat::test_that("exact title duplicates take priority", {
  master <- tibble::tibble(
    record_id = "m1",
    title = "Atlantic salmon health",
    abstract = "Master abstract",
    doi = "10.1000/master",
    authors = "Smith, A",
    year = 2024
  )

  incoming <- tibble::tibble(
    record_id = "n1",
    title = "Atlantic salmon health",
    abstract = "Incoming abstract",
    doi = "10.1000/different",
    authors = "Jones, B",
    year = 2024
  )

  result <- deduplicate_new_records(incoming, master)

  testthat::expect_equal(result$duplicate_status, "duplicate")
  testthat::expect_equal(result$duplicate_basis, "exact normalised title")
  testthat::expect_equal(result$matched_master_record_id, "m1")
})

testthat::test_that("matching DOI with compatible title is a duplicate", {
  master <- tibble::tibble(
    record_id = "m1",
    title = "Health effects in Atlantic salmon",
    abstract = "Master abstract",
    doi = "10.1000/example",
    authors = "Smith, A",
    year = 2024
  )

  incoming <- tibble::tibble(
    record_id = "n1",
    title = "Health effects of Atlantic salmon",
    abstract = "Incoming abstract",
    doi = "doi:10.1000/example",
    authors = "Jones, B",
    year = 2024
  )

  result <- deduplicate_new_records(incoming, master)

  testthat::expect_equal(result$duplicate_status, "duplicate")
  testthat::expect_equal(result$matched_master_record_id, "m1")
})

testthat::test_that("non-matching records remain new", {
  master <- tibble::tibble(
    record_id = "m1",
    title = "Atlantic salmon disease",
    abstract = "Master abstract",
    doi = "10.1000/example",
    authors = "Smith, A",
    year = 2024
  )

  incoming <- tibble::tibble(
    record_id = "n1",
    title = "Completely different topic",
    abstract = "Incoming abstract",
    doi = "10.1000/other",
    authors = "Jones, B",
    year = 2025
  )

  result <- deduplicate_new_records(incoming, master)

  testthat::expect_equal(result$duplicate_status, "new")
  testthat::expect_equal(result$matched_master_record_id, NA_character_)
})
