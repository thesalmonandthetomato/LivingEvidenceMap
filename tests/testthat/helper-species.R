# Load the species components directly for focused unit tests.
# Package installation and namespace/export design will be added once the
# core modules are stable; these tests deliberately exercise the source files.

source(file.path("R", "target.R"), local = FALSE)
source(file.path("R", "species_detect.R"), local = FALSE)
source(file.path("R", "species_assign.R"), local = FALSE)
