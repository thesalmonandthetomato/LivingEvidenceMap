# Small API smoke tests for screening, species/geography adjudication, and topics.
# One representative request per stage; never run this over the evidence-map corpus.

if (!nzchar(Sys.getenv("OPENAI_API_KEY"))) stop("OPENAI_API_KEY is not set")

source("R/llm-screening.R")
source("R/llm-adjudication.R")
source("R/topics.R")

cat("Screening interface: ")
stopifnot(exists("salmon_llm_system_prompt"), exists("salmon_llm_response_schema"), exists("extract_openai_output_text"))
cat("OK\n")

cat("Species/geography adjudication interface: ")
stopifnot(exists("adjudicate_species_geography"))
adjudicate_species_geography(list(
  title = "Atlantic salmon farming",
  abstract = "Representative smoke-test record."
))
cat("OK\n")

cat("Topics interface: ")
stopifnot(exists("classify_topics"))
classify_topics(data.frame(
  title = "Atlantic salmon farming",
  abstract = "Representative smoke-test record."
))
cat("OK\n")

cat("All three LLM smoke tests completed.\n")
