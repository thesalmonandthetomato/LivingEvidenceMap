# W07 Shiny-only evidence checks. No topic-specific assumptions.
w07_evidence_normalise <- function(x) {
  x <- iconv(as.character(x),to="ASCII//TRANSLIT",sub="")
  x[is.na(x)] <- ""
  x <- tolower(x)
  x <- gsub("[^[:alnum:]]+"," ",x)
  trimws(gsub("[[:space:]]+"," ",x))
}
w07_evidence_supported <- function(quotation,title,abstract) {
  q <- w07_evidence_normalise(quotation)
  source <- w07_evidence_normalise(paste(title,abstract))
  nzchar(q) && grepl(q,source,fixed=TRUE)
}
w07_validate_model_coding <- function(coding,allowed,title,abstract) {
  issues <- character()
  assignments <- coding$assignments %||% list()
  ids <- vapply(assignments,function(x)as.character(x$path_id %||% ""),
                character(1))
  if(anyDuplicated(ids))issues <- c(issues,"duplicate_ontology_codes")
  if(any(!ids %in% allowed))issues <- c(issues,"unknown_ontology_codes")
  for(i in seq_along(assignments)) {
    a <- assignments[[i]]
    if(!w07_evidence_supported(a$evidence %||% "",title,abstract))
      issues <- c(issues,paste0("unsupported_evidence_assignment_",i))
  }
  unique(issues)
}
`%||%` <- function(x,y)if(is.null(x)||!length(x))y else x
