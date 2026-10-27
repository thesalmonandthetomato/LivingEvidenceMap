w07_review_handoff_validate <- function(x,review_id,run_id) {
  if(!identical(as.character(x$schema %||% ""),"lem-w07-human-reviewed-subset-v1") ||
     !identical(as.character(x$review_id %||% ""),as.character(review_id)) ||
     !identical(as.character(x$run_id %||% ""),as.character(run_id)) ||
     !identical(as.character(x$status %||% ""),"review_complete_not_published"))
    stop("W07 handoff identity or schema mismatch",call.=FALSE)
  if(!nzchar(as.character(x$completed_by %||% "")))
    stop("Missing W07 completion actor",call.=FALSE)
  if(!grepl("^[a-f0-9]{64}$",as.character(x$sha256 %||% "")))
    stop("Missing W07 handoff payload checksum",call.=FALSE)
  records <- x$model_results %||% list()
  events <- x$decision_events %||% list()
  if(!length(records)||length(records)!=length(events))
    stop("W07 handoff is incomplete",call.=FALSE)
  ids <- vapply(records,function(z)as.character(z$record_id %||% ""),character(1))
  done <- vapply(events,function(z)as.character(z$record_id %||% ""),character(1))
  if(any(!nzchar(ids))||anyDuplicated(ids)||!identical(ids,done))
    stop("W07 reviewed record IDs do not match source results",call.=FALSE)
  for(e in events) {
    if(!identical(as.character(e$run_id %||% ""),as.character(run_id)) ||
       !identical(as.character(e$review_id %||% ""),as.character(review_id)) ||
       !nzchar(as.character(e$user_id %||% "")) ||
       !as.character(e$relevance %||% "") %in%
         c("CODED_IN_SCOPE","IN_SCOPE_ONTOLOGY_GAP","INSUFFICIENT_INFORMATION"))
      stop("W07 handoff has unauthorised or inconsistent review decisions",call.=FALSE)
    if(!identical(as.character(e$ontology_sha %||% ""),
                  as.character(x$manifest$ontology_sha256 %||% "")) ||
       !identical(as.character(e$prompt_sha %||% ""),
                  as.character(x$manifest$prompt_sha256 %||% "")) ||
       !grepl("^[a-f0-9]{64}$",as.character(e$queue_sha256 %||% "")))
      stop("W07 handoff provenance mismatch",call.=FALSE)
  }
  if(length(unique(vapply(events,function(e)as.character(e$queue_sha256),
                          character(1))))!=1L)
    stop("W07 handoff has multiple queue versions",call.=FALSE)
  invisible(TRUE)
}
