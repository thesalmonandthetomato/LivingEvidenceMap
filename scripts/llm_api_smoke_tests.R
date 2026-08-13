# Small, production-safe API smoke tests for screening, adjudication and topics.
# Requires OPENAI_API_KEY in the environment. Never writes the key to disk.

source("R/llm_screening.R")
source("R/llm_adjudication.R")

source_if_exists <- function(path) if (file.exists(path)) source(path)
source_if_exists("R/topic_classification.R")
source_if_exists("R/topics.R")

stopifnot(nzchar(Sys.getenv("OPENAI_API_KEY")))

screen_test <- data.frame(
  title = "Salmon farming production and environmental interactions",
  abstract = "A study of environmental effects associated with farmed salmon production.",
  stringsAsFactors = FALSE
)

if (exists("screen_relevance_llm")) {
  screen_relevance_llm(screen_test[1, , drop = FALSE])
} else if (exists("screen_with_llm")) {
  screen_with_llm(screen_test[1, , drop = FALSE])
} else {
  stop("No established LLM screening entry point found")
}

adj_test <- data.frame(
  title = "Salmon aquaculture in Norway",
  abstract = "The study examines salmon farming in Norway and reports production impacts.",
  stringsAsFactors = FALSE
)

if (exists("adjudicate_species_geography_llm")) {
  adjudicate_species_geography_llm(adj_test[1, , drop = FALSE])
} else if (exists("adjudicate_llm")) {
  adjudicate_llm(adj_test[1, , drop = FALSE])
} else {
  stop("No established LLM adjudication entry point found")
}

topic_fns <- c("classify_topics_llm", "classify_topic_llm", "assign_topics_llm")
found <- topic_fns[vapply(topic_fns, exists, logical(1))]
if (!length(found)) stop("No established LLM topic entry point found")
get(found[[1]])(adj_test[1, , drop = FALSE])

cat("LLM smoke tests completed: screening, adjudication, topics (1 record each).\n")
