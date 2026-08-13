source(testthat::test_path("..", "..", "R", "relevance_screening.R"), local = FALSE)
source(testthat::test_path("..", "..", "R", "load_relevance_model.R"), local = FALSE)

testthat::test_that("saved relevance model contains the validated model and thresholds", {
  path <- testthat::test_path(
    "..", "..", "models", "relevance",
    "salmon_farming_relevance_model.rds"
  )

  testthat::expect_true(file.exists(path))

  bundle <- load_relevance_model(path)

  testthat::expect_true(is.list(bundle$model))
  testthat::expect_true(is.list(bundle$thresholds))
  testthat::expect_true(is.numeric(bundle$thresholds$exclude_threshold))
  testthat::expect_true(is.numeric(bundle$thresholds$include_threshold))
  testthat::expect_lt(
    bundle$thresholds$exclude_threshold,
    bundle$thresholds$include_threshold
  )
  testthat::expect_equal(bundle$thresholds$target_sensitivity, 0.99)
  testthat::expect_equal(bundle$thresholds$target_precision, 0.95)
})

testthat::test_that("production screening uses the thresholds stored with the model", {
  path <- testthat::test_path(
    "..", "..", "models", "relevance",
    "salmon_farming_relevance_model.rds"
  )
  bundle <- load_relevance_model(path)

  testthat::expect_true(
    identical(
      names(bundle$thresholds)[1:2],
      c("exclude_threshold", "include_threshold")
    )
  )
})
