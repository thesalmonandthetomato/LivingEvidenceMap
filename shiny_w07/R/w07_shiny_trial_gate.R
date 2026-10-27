# W07 Shiny only: fail-closed, review-scoped trial configuration gate.
# Pure validation. No Zenodo mutation, model execution or production workflow.
w07_trial_sha <- function(content) digest::digest(content,algo="sha256",serialize=FALSE)
w07_trial_validate_version <- function(object,approval,review_id,type,expected_sha) {
  stopifnot(type %in% c("ontology","prompt"))
  sha <- as.character(expected_sha)
  name <- paste0("w07-",type,"-",sha,".json")
  if(length(sha)!=1L || !grepl("^[0-9a-f]{64}$",sha) ||
     !identical(object$schema,"lem-w07-shiny-configuration-v1") ||
     !identical(object$review_id,review_id) ||
     !identical(object$type,type) ||
     !identical(object$sha256,sha) ||
     !is.character(object$content) || length(object$content)!=1L ||
     !nzchar(trimws(object$content)) ||
     !identical(w07_trial_sha(object$content),sha) ||
     (!is.null(approval) && (
       !identical(approval$schema,"lem-w07-shiny-approval-v1") ||
       !identical(approval$review_id,review_id) ||
       !identical(approval$type,type) ||
       !identical(approval$sha256,sha) ||
       !identical(approval$filename,name))))
    stop("W07 ",type," version failed checksum or review verification",call.=FALSE)
  if(identical(type,"ontology")) {
    ontology <- utils::read.csv(text=object$content,stringsAsFactors=FALSE,
                                check.names=FALSE)
    required <- c("path_id","level_1","level_2","level_3","definition")
    if(!all(required %in% names(ontology)) || !nrow(ontology) ||
       anyDuplicated(ontology$path_id) ||
       anyNA(ontology$path_id) || any(!nzchar(trimws(ontology$path_id))) ||
       anyNA(ontology$definition) || any(!nzchar(trimws(ontology$definition))))
      stop("Approved W07 ontology is invalid",call.=FALSE)
    return(ontology)
  }
  object$content
}
w07_trial_validate_size <- function(n,total) {
  n <- suppressWarnings(as.integer(n))
  if(length(n)!=1L||is.na(n)||n<1L||n>total)
    stop("Invalid W07 subset size",call.=FALSE)
  n
}
w07_trial_prepare <- function(records,n,ontology,prompt,review_id,source_sha,
                              ontology_sha,prompt_sha) {
  stopifnot(identical(names(records),c("record_id","title","abstract")))
  n <- w07_trial_validate_size(n,nrow(records))
  if(anyDuplicated(records$record_id) || anyNA(records$record_id) ||
     any(!nzchar(records$record_id)))
    stop("Invalid W07 record identifiers",call.=FALSE)
  selected <- utils::head(records,n)
  list(records=selected,
       manifest=list(schema="lem-w07-shiny-subset-input-v1",mode="subset_test",
         review_id=review_id,source_stage="W05",w06_bypassed=TRUE,
         source_input_sha256=source_sha,ontology_sha256=ontology_sha,
         prompt_sha256=prompt_sha,subset_records=n,
         ontology_categories=nrow(ontology)))
}
