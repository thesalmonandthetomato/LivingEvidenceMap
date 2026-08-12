testthat::test_that("Bramer pass A detects duplicate despite DOI differences", {
  records <- data.frame(
    record_id = c("A", "B"),
    title = c("Effects of salmon farming", "Effects of salmon farming"),
    authors = c("Smith J | Jones A", "Smith J | Jones A"),
    year = c(2020, 2020),
    journal = c("Aquaculture", "Aquaculture"),
    volume = c("10", "10"),
    issue = c("2", "2"),
    pages = c("100-110", "100-110"),
    doi = c("10.1234/wrong-one", "10.1234/wrong-two"),
    stringsAsFactors = FALSE
  )

  result <- deduplicate_records(records)
  testthat::expect_true(any(result$automatic_duplicates$method == "A_author_year_title_journal"))
  testthat::expect_equal(nrow(result$automatic_duplicates), 1L)
})

testthat::test_that("wrong DOI alone does not make distinct records duplicates", {
  records <- data.frame(
    record_id = c("A", "B"),
    title = c("Effects of salmon farming", "Effects of trout farming"),
    authors = c("Smith J", "Brown K"),
    year = c(2020, 2021),
    journal = c("Aquaculture", "Aquaculture"),
    volume = c("10", "11"),
    issue = c("2", "3"),
    pages = c("100-110", "200-210"),
    doi = c("10.1234/same", "10.1234/same"),
    stringsAsFactors = FALSE
  )

  result <- deduplicate_records(records)
  testthat::expect_equal(nrow(result$automatic_duplicates), 0L)
})

testthat::test_that("Bramer pass B handles missing journal", {
  records <- data.frame(
    record_id = c("A", "B"),
    title = c("Salmon welfare study", "Salmon welfare study"),
    authors = c("Smith J", "Smith J"),
    year = c(2019, 2019),
    journal = c(NA, NA),
    volume = c(NA, NA),
    issue = c(NA, NA),
    pages = c("1-9", "1-9"),
    stringsAsFactors = FALSE
  )

  result <- deduplicate_records(records)
  testthat::expect_true(any(result$automatic_duplicates$method == "B_author_year_title_pages"))
})

testthat::test_that("weaker Bramer matches are returned for review", {
  records <- data.frame(
    record_id = c("A", "B"),
    title = c("Salmon farming and welfare", "Salmon farming and welfare"),
    authors = c("Smith J", "Brown K"),
    year = c(2020, 2021),
    journal = c("Aquaculture", "Aquaculture"),
    volume = c("10", "10"),
    issue = c("2", "2"),
    pages = c("100-110", "100-110"),
    stringsAsFactors = FALSE
  )

  result <- deduplicate_records(records)
  testthat::expect_true(any(result$review_candidates$method == "C_title_volume_pages"))
  testthat::expect_equal(nrow(result$automatic_duplicates), 0L)
})

testthat::test_that("existing corpus record remains canonical", {
  incoming <- data.frame(
    record_id = "NEW",
    title = "Salmon farming and welfare",
    authors = "Smith J",
    year = 2020,
    journal = "Aquaculture",
    volume = "10",
    issue = "2",
    pages = "100-110",
    stringsAsFactors = FALSE
  )
  existing <- incoming
  existing$record_id <- "EXISTING"

  result <- deduplicate_records(incoming, existing)
  testthat::expect_equal(result$automatic_duplicates$canonical_record_id, "EXISTING")
  testthat::expect_equal(result$automatic_duplicates$duplicate_record_id, "NEW")
})

testthat::test_that("within-import duplicate keeps first record canonical", {
  records <- data.frame(
    record_id = c("FIRST", "SECOND"),
    title = c("Salmon farming and welfare", "Salmon farming and welfare"),
    authors = c("Smith J", "Smith J"),
    year = c(2020, 2020),
    journal = c("Aquaculture", "Aquaculture"),
    volume = c("10", "10"),
    issue = c("2", "2"),
    pages = c("100-110", "100-110"),
    stringsAsFactors = FALSE
  )

  result <- deduplicate_records(records)
  testthat::expect_equal(result$automatic_duplicates$canonical_record_id, "FIRST")
  testthat::expect_equal(result$automatic_duplicates$duplicate_record_id, "SECOND")
})
