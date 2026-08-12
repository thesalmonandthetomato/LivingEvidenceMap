# Resolve the project root from this helper's location rather than the
# process working directory used by GitHub Actions.
source(testthat::test_path("..", "..", "R", "geography_detect.R"), local = FALSE)
