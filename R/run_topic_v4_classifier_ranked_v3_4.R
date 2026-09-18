# Luna ranked topic classifier v3.4.
#
# This version adds an exclusive fallback rule for pathways labelled General.
# The underlying v3.3 runner remains the implementation source so all other
# classification logic stays unchanged.

Sys.setenv(TOPIC_GENERAL_CODE_EXCLUSIVITY = "true")
if (!nzchar(Sys.getenv("TOPIC_ONTOLOGY_PATH", ""))) {
  Sys.setenv(TOPIC_ONTOLOGY_PATH = "data/reference/topic_ontology_v3_4.csv")
}
source("R/run_topic_v4_classifier_ranked_v3_1.R", chdir = FALSE)
