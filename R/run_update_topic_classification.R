# Weekly/update topic-classification entry point.
# Scientific classification logic lives in R/run_topic_v4_classifier.R and is
# ported from the validated full-corpus V4 classifier in
# nealhaddaway/salmonscopingreview scripts/52_run_topic_v4_full_corpus.R.

if (!nzchar(Sys.getenv("TOPIC_INPUT_PATH"))) {
  Sys.setenv(TOPIC_INPUT_PATH = "data/updates/2026-08-13_lens/records_after_species_geography_adjudication.csv")
}
if (!nzchar(Sys.getenv("TOPIC_ONTOLOGY_PATH"))) {
  Sys.setenv(TOPIC_ONTOLOGY_PATH = "data/reference/topic_ontology_v3.csv")
}
if (!nzchar(Sys.getenv("TOPIC_OUTPUT_DIR"))) {
  Sys.setenv(TOPIC_OUTPUT_DIR = "data/updates/2026-08-13_lens/topic_classification_v3")
}
if (!nzchar(Sys.getenv("TOPIC_MODEL"))) {
  Sys.setenv(TOPIC_MODEL = "gpt-5.6-luna")
}
if (!nzchar(Sys.getenv("TOPIC_REASONING_EFFORT"))) {
  Sys.setenv(TOPIC_REASONING_EFFORT = "medium")
}

source("R/run_topic_v4_classifier.R")
