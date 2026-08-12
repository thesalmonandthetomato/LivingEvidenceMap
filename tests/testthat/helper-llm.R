# Load the LLM adjudication and screening cores for tests without making API calls.
source(testthat::test_path("..", "..", "R", "llm_adjudication.R"), local = FALSE)
source(testthat::test_path("..", "..", "R", "llm_screening.R"), local = FALSE)
