# Luna ranked topic classifier v3.4.
#
# This version adds an exclusive fallback rule for pathways labelled General.
# The underlying v3.3 runner remains the implementation source so all other
# classification logic stays unchanged.

Sys.setenv(TOPIC_GENERAL_CODE_EXCLUSIVITY = "true")
source("R/run_topic_v4_classifier_ranked_v3_1.R", chdir = FALSE)
