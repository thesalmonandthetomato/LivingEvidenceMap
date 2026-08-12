testthat::test_that("salmon LLM prompt preserves eligibility scope", {
  prompt <- salmon_llm_system_prompt()
  testthat::expect_match(prompt, "Atlantic salmon")
  testthat::expect_match(prompt, "rainbow trout")
  testthat::expect_match(prompt, "wild salmonids")
  testthat::expect_match(prompt, "Use UNCERTAIN only as a last resort")
})

testthat::test_that("LLM response schema has only the established decisions", {
  schema <- salmon_llm_response_schema()
  testthat::expect_identical(schema$properties$decision$enum, c("retain", "exclude", "uncertain"))
  testthat::expect_identical(schema$required, c("decision", "reason"))
})

testthat::test_that("OpenAI output text extraction handles message output", {
  response <- list(output=list(list(type="message", content=list(list(type="output_text", text='{"decision":"retain","reason":"Salmon farming is substantive."}')))))
  testthat::expect_match(extract_openai_output_text(response), "retain")
})
