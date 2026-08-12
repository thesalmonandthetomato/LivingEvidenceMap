testthat::test_that("target validation accepts a valid target", {
  records <- data.frame(
    record_sequence = 1:2,
    record_id = c("A", "B"),
    title = c("One", "Two"),
    abstract = c("A", "B"),
    stringsAsFactors = FALSE
  )
  testthat::expect_invisible(validate_target_records(records, "TEST"))
})

testthat::test_that("target validation rejects duplicated identifiers", {
  records <- data.frame(
    record_sequence = c(1L, 2L),
    record_id = c("A", "A"),
    title = c("One", "Two"),
    abstract = c("A", "B"),
    stringsAsFactors = FALSE
  )
  testthat::expect_error(validate_target_records(records, "TEST"), "unique")
})

testthat::test_that("target validation rejects missing required columns", {
  records <- data.frame(record_sequence = 1L, record_id = "A")
  testthat::expect_error(validate_target_records(records, "TEST"), "missing")
})

testthat::test_that("target configuration resolves relative record paths", {
  path <- tempfile(fileext = ".yml")
  on.exit(unlink(path), add = TRUE)
  writeLines(c(
    "target:",
    "  name: TEST",
    "  records_file: records.csv"
  ), con = path)
  config <- read_target_config(path)
  testthat::expect_equal(config$target$name, "TEST")
  testthat::expect_true(fs::is_absolute_path(config$target$records_file))
})

testthat::test_that("target manifest records the declared target and record count", {
  records <- data.frame(
    record_sequence = 10:11,
    record_id = c("A", "B"),
    title = c("One", "Two"),
    abstract = c("A", "B"),
    stringsAsFactors = FALSE
  )
  target <- list(
    config = list(target = list(name = "TEST", records_file = "/tmp/records.csv")),
    records = records
  )
  out <- write_target_manifest(target, "/tmp/test-target.yml", tempfile())
  manifest <- readr::read_csv(out, show_col_types = FALSE)
  testthat::expect_equal(manifest$target_name, "TEST")
  testthat::expect_equal(manifest$n_records, 2)
})
