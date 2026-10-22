# Schema-independent relevance rules for Shiny-only W07 experiments.
w07_relevance_validate <- function(coding) {
  outcome <- coding$relevance$status
  allowed <- c("CODED_IN_SCOPE","IN_SCOPE_ONTOLOGY_GAP","OUT_OF_SCOPE","INSUFFICIENT_INFORMATION")
  if(!is.character(outcome)||length(outcome)!=1L||!outcome %in% allowed)
    return("invalid_relevance_status")
  n <- length(coding$assignments %||% list())
  if(n>0L && !identical(outcome,"CODED_IN_SCOPE"))
    return("coded_record_has_inconsistent_relevance")
  if(n==0L && identical(outcome,"CODED_IN_SCOPE"))
    return("zero_codes_have_inconsistent_relevance")
  if(n==0L && !nzchar(trimws(as.character(coding$relevance$explanation %||% ""))))
    return("zero_codes_missing_relevance_explanation")
  if(identical(outcome,"IN_SCOPE_ONTOLOGY_GAP") &&
     !nzchar(trimws(as.character(coding$relevance$candidate_category %||% ""))))
    return("ontology_gap_missing_candidate_category")
  character()
}
