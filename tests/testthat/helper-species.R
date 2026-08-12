# Load the species components directly for focused unit tests.
#
# Resolve paths from the test file rather than relying on the process working
# directory. This keeps the tests reproducible under both testthat and CI.

project_root <- normalizePath(
  file.path(testthat::test_path(), "..", ".."),
  mustWork = TRUE
)

source(file.path(project_root, "R", "target.R"), local = FALSE)
source(file.path(project_root, "R", "species_detect.R"), local = FALSE)
source(file.path(project_root, "R", "species_assign.R"), local = FALSE)
