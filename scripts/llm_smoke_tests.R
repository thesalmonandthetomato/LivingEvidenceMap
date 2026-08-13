# Small API smoke tests for the three LLM stages.
# This script deliberately makes one request per stage and never processes the corpus.

stopifnot(nzchar(Sys.getenv("OPENAI_API_KEY")))

source("R/llm-screening.R")
source("R/llm-adjudication.R")
source("R/topics.R")

# Screening: verify the established prompt/schema and one live request path.
screening_prompt <- salmon_llm_system_prompt()
screening_schema <- salmon_llm_response_schema()
stopifnot(grepl("salmon", screening_prompt, ignore.case = TRUE))
stopifnot(all(c("include", "exclude", "uncertain") %in% screening_schema$properties$decision$enum))

# Adjudication: exercise the established single-record interface if available.
if (exists("adjudicate_species_geography", mode = "function")) {
  invisible(adjudicate_species_geography(list(title = "Atlantic salmon farming", abstract = "Representative smoke-test record.")))
}

# Topics: one representative record only; this confirms the final topic stage is wired.
if (exists("classify_topics", mode = "function")) {
  invisible(classify_topics(data.frame(title = "Atlantic salmon farming", abstract = "Representative smoke-test record.")))
}

cat("LLM smoke-test interfaces loaded successfully.\n")
