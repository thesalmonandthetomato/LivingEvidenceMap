# Load the LLM adjudication core for tests without making API calls.
source(testthat::test_path("..", "..", "R", "llm_adjudication.R"), local = FALSE)
