testthat::test_that("geography detection prefers longest overlapping place names", {
  records <- data.frame(
    record_sequence = 1L,
    record_id = "A",
    title = "Study in New Zealand",
    abstract = "",
    stringsAsFactors = FALSE
  )
  gazetteer <- data.frame(
    matched_place = c("Zealand", "New Zealand"),
    normalised_match = c("zealand", "new zealand"),
    country_name = c("New Zealand", "New Zealand"),
    region_name = c("Oceania", "Oceania"),
    stringsAsFactors = FALSE
  )

  hits <- detect_geography_mentions(records, gazetteer)
  testthat::expect_equal(nrow(hits), 1L)
  testthat::expect_equal(hits$matched_text, "New Zealand")
})

testthat::test_that("geography detection searches title and abstract", {
  records <- data.frame(
    record_sequence = c(1L, 2L),
    record_id = c("A", "B"),
    title = c("Aquaculture in Norway", "Aquaculture study"),
    abstract = c("", "The work was conducted in Chile."),
    stringsAsFactors = FALSE
  )
  gazetteer <- data.frame(
    matched_place = c("Norway", "Chile"),
    normalised_match = c("norway", "chile"),
    country_name = c("Norway", "Chile"),
    region_name = c("Europe", "South America"),
    stringsAsFactors = FALSE
  )

  hits <- detect_geography_mentions(records, gazetteer)
  testthat::expect_setequal(hits$country_name, c("Norway", "Chile"))
  testthat::expect_setequal(hits$source, c("title", "abstract"))
})

testthat::test_that("geography detector rejects duplicate target identifiers", {
  records <- data.frame(
    record_sequence = c(1L, 2L),
    record_id = c("A", "A"),
    title = c("a", "b"),
    abstract = c("", ""),
    stringsAsFactors = FALSE
  )
  gazetteer <- data.frame(
    matched_place = "Norway", normalised_match = "norway",
    country_name = "Norway", region_name = "Europe",
    stringsAsFactors = FALSE
  )

  testthat::expect_error(
    detect_geography_mentions(records, gazetteer),
    "unique record_id"
  )
})
