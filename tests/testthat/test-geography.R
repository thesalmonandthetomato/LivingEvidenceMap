testthat::test_that("geography detection prefers longest overlapping place names", {
  records <- data.frame(record_sequence = 1L, record_id = "A", title = "Study in New Zealand", abstract = "", stringsAsFactors = FALSE)
  gazetteer <- data.frame(matched_place = c("Zealand", "New Zealand"), normalised_match = c("zealand", "new zealand"), country_name = c("New Zealand", "New Zealand"), iso3c = c("NZL", "NZL"), region_name = c("Oceania", "Oceania"), stringsAsFactors = FALSE)
  hits <- detect_geography_mentions(records, gazetteer)
  testthat::expect_equal(nrow(hits), 1L)
  testthat::expect_equal(hits$matched_text, "New Zealand")
})

testthat::test_that("geography detection searches title and abstract", {
  records <- data.frame(record_sequence = c(1L, 2L), record_id = c("A", "B"), title = c("Aquaculture in Norway", "Aquaculture study"), abstract = c("", "The work was conducted in Chile."), stringsAsFactors = FALSE)
  gazetteer <- data.frame(matched_place = c("Norway", "Chile"), normalised_match = c("norway", "chile"), country_name = c("Norway", "Chile"), iso3c = c("NOR", "CHL"), region_name = c("Europe", "South America"), stringsAsFactors = FALSE)
  hits <- detect_geography_mentions(records, gazetteer)
  testthat::expect_setequal(hits$country_name, c("Norway", "Chile"))
  testthat::expect_setequal(hits$source, c("title", "abstract"))
})

testthat::test_that("geography detector rejects duplicate target identifiers", {
  records <- data.frame(record_sequence = c(1L, 2L), record_id = c("A", "A"), title = c("a", "b"), abstract = c("", ""), stringsAsFactors = FALSE)
  gazetteer <- data.frame(matched_place = "Norway", normalised_match = "norway", country_name = "Norway", iso3c = "NOR", region_name = "Europe", stringsAsFactors = FALSE)
  testthat::expect_error(detect_geography_mentions(records, gazetteer), "unique record_id")
})

testthat::test_that("primary country gives strict precedence to a title country", {
  mentions <- data.frame(record_sequence = c(1L, 1L), record_id = c("A", "A"), source = c("title", "abstract"), matched_text = c("Norway", "Chile"), country_name = c("Norway", "Chile"), iso3c = c("NOR", "CHL"), region_name = c("Europe", "South America"), context = c("Norway aquaculture", "study conducted in Chile"), stringsAsFactors = FALSE)
  result <- assign_primary_country(mentions)
  testthat::expect_equal(result$summary$primary_iso3c, "NOR")
  testthat::expect_false(result$summary$review_required)
})

testthat::test_that("primary country retains multiple countries explicitly co-named in title", {
  mentions <- data.frame(record_sequence = c(1L, 1L), record_id = c("A", "A"), source = c("title", "title"), matched_text = c("Norway", "Chile"), country_name = c("Norway", "Chile"), iso3c = c("NOR", "CHL"), region_name = c("Europe", "South America"), context = c("Norway", "Chile"), stringsAsFactors = FALSE)
  result <- assign_primary_country(mentions)
  testthat::expect_equal(result$summary$primary_country_count, 2L)
  testthat::expect_setequal(strsplit(result$summary$primary_iso3c, "; ")[[1]], c("CHL", "NOR"))
})

testthat::test_that("exact abstract country ties are sent to review", {
  mentions <- data.frame(record_sequence = c(1L, 1L), record_id = c("A", "A"), source = c("abstract", "abstract"), matched_text = c("Norway", "Chile"), country_name = c("Norway", "Chile"), iso3c = c("NOR", "CHL"), region_name = c("Europe", "South America"), context = c("fish industry", "fish industry"), stringsAsFactors = FALSE)
  result <- assign_primary_country(mentions)
  testthat::expect_true(result$summary$review_required)
  testthat::expect_equal(result$review_queue$review_reason, "Abstract candidates remain exactly tied")
})

testthat::test_that("regional title scope is sent to review", {
  mentions <- data.frame(record_sequence = c(1L, 1L), record_id = c("A", "A"), source = c("title", "abstract"), matched_text = c("Europe", "Norway"), country_name = c(NA, "Norway"), iso3c = c(NA, "NOR"), region_name = c("Europe", "Europe"), context = c("Europe aquaculture", "study conducted in Norway"), stringsAsFactors = FALSE)
  result <- assign_primary_country(mentions)
  testthat::expect_true(result$summary$review_required)
  testthat::expect_equal(result$summary$primary_country_count, 0L)
})
