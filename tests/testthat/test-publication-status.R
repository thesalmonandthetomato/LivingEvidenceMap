testthat::test_that("publication notices are identified from titles", {
  testthat::expect_equal(identify_publication_notices("Retraction: Salmon population dynamics"), "retraction_notice")
  testthat::expect_equal(identify_publication_notices("Withdrawal: Salmon study"), "withdrawal_notice")
  testthat::expect_equal(identify_publication_notices("Correction: Salmon study"), "correction_notice")
  testthat::expect_true(is.na(identify_publication_notices("Salmon population dynamics")))
})

testthat::test_that("DOIs are normalised for OpenAlex lookup", {
  testthat::expect_equal(normalise_doi_for_openalex("https://doi.org/10.1234/ABC"), "10.1234/abc")
  testthat::expect_equal(normalise_doi_for_openalex("doi:10.1234/ABC"), "10.1234/abc")
})

testthat::test_that("OpenAlex retraction result is used without live API access", {
  fake_lookup <- function(doi, api_key = NULL) {
    tibble::tibble(doi_for_lookup=doi, openalex_id="OA", openalex_title="Test salmon paper", openalex_is_retracted=identical(doi, "10.1234/retracted"), openalex_lookup_status="matched", openalex_error=NA_character_)
  }
  records <- data.frame(record_id=c("LIVE","RETRACTED","NOTICE","NO_DOI"), title=c("Salmon paper","Retracted salmon paper","Retraction: Salmon paper","Salmon paper without DOI"), doi=c("10.1234/live","10.1234/retracted","10.1234/notice",""), stringsAsFactors=FALSE)
  result <- check_publication_status(records, lookup_fun=fake_lookup)
  testthat::expect_false(result$audit$remove_publication_status[result$audit$record_id=="LIVE"])
  testthat::expect_true(result$audit$remove_publication_status[result$audit$record_id=="RETRACTED"])
  testthat::expect_equal(result$audit$removal_reason[result$audit$record_id=="RETRACTED"], "retracted_original")
  testthat::expect_true(result$audit$remove_publication_status[result$audit$record_id=="NOTICE"])
  testthat::expect_equal(result$audit$removal_reason[result$audit$record_id=="NOTICE"], "retraction_notice")
  testthat::expect_false(result$audit$remove_publication_status[result$audit$record_id=="NO_DOI"])
})

testthat::test_that("OpenAlex failures do not remove records", {
  failing_lookup <- function(doi, api_key=NULL) tibble::tibble(doi_for_lookup=doi, openalex_id=NA_character_, openalex_title=NA_character_, openalex_is_retracted=FALSE, openalex_lookup_status="failed", openalex_error="test failure")
  records <- data.frame(record_id="A", title="Salmon paper", doi="10.1234/test", stringsAsFactors=FALSE)
  result <- check_publication_status(records, lookup_fun=failing_lookup)
  testthat::expect_false(result$audit$remove_publication_status)
  testthat::expect_equal(result$audit$openalex_lookup_status, "failed")
})

testthat::test_that("duplicate DOIs are looked up only once", {
  calls <- character()
  counting_lookup <- function(doi, api_key=NULL) { calls <<- c(calls, doi); tibble::tibble(doi_for_lookup=doi, openalex_id="OA", openalex_title="Test", openalex_is_retracted=FALSE, openalex_lookup_status="matched", openalex_error=NA_character_) }
  records <- data.frame(record_id=c("A","B"), title=c("A","B"), doi=c("10.1234/same","10.1234/same"), stringsAsFactors=FALSE)
  check_publication_status(records, lookup_fun=counting_lookup)
  testthat::expect_equal(calls, "10.1234/same")
})
