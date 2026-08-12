testthat::test_that("RIS parser reads records and normalises DOI", {
  path <- tempfile(fileext = ".ris")
  on.exit(unlink(path), add = TRUE)
  writeLines(c(
    "TY  - JOUR",
    "ID  - R1",
    "TI  - Salmon <b>welfare</b> study",
    "AU  - Smith, J",
    "AU  - Jones, A",
    "AB  - An &amp; important study.",
    "DO  - https://doi.org/10.1234/ABC.1",
    "PY  - 2024",
    "T2  - Aquaculture",
    "VL  - 12",
    "IS  - 3",
    "SP  - 10-20",
    "ER  -"
  ), path)

  records <- read_corpus(path)
  testthat::expect_equal(nrow(records), 1L)
  testthat::expect_equal(records$record_id, "R1")
  testthat::expect_equal(records$doi, "10.1234/abc.1")
  testthat::expect_equal(records$year, 2024L)
  testthat::expect_equal(records$abstract, "An & important study.")
  testthat::expect_true(records$has_valid_doi)
  testthat::expect_equal(records$record_sequence, 1L)
})

testthat::test_that("RIS continuation lines are retained", {
  path <- tempfile(fileext = ".ris")
  on.exit(unlink(path), add = TRUE)
  writeLines(c(
    "TY  - JOUR",
    "ID  - R1",
    "TI  - A long title",
    "      continued title text",
    "AU  - Smith, J",
    "PY  - 2023",
    "ER  -"
  ), path)

  records <- read_corpus(path)
  testthat::expect_equal(records$title, "A long title continued title text")
})

testthat::test_that("multiple RIS records preserve sequence", {
  path <- tempfile(fileext = ".ris")
  on.exit(unlink(path), add = TRUE)
  writeLines(c(
    "TY  - JOUR", "ID  - A", "TI  - First", "ER  -",
    "TY  - JOUR", "ID  - B", "TI  - Second", "ER  -"
  ), path)

  records <- read_corpus(path)
  testthat::expect_equal(records$record_sequence, c(1L, 2L))
  testthat::expect_equal(records$record_id, c("A", "B"))
})

testthat::test_that("author table preserves author order", {
  records <- tibble::tibble(
    record_sequence = 1L,
    record_id = "R1",
    authors = "Smith, J | Jones, A"
  )
  authors <- make_authors_long(records)
  testthat::expect_equal(authors$author_order, c(1L, 2L))
})
