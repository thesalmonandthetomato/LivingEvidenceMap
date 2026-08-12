# Resolve paths from the test helper rather than the process working directory.
source(testthat::test_path("..", "..", "R", "geography_detect.R"), local = FALSE)
source(testthat::test_path("..", "..", "R", "geography_primary_country.R"), local = FALSE)
