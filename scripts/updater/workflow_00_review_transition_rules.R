# Pure review-specific W00 transition rules; independent of Google Sheets API.
w00_review_transition <- function(metadata, events, review_id, run_id, action, record_id="") {
  if(!all(c("key","value") %in% names(metadata))) stop("Invalid metadata columns",call.=FALSE)
  if(!all(c("event_id","github_run_id","event_type","zenodo_record_id") %in% names(events)))
    stop("Invalid event columns",call.=FALSE)
  keys<-as.character(metadata$key)
  if(anyNA(keys)||anyDuplicated(keys)||any(!nzchar(keys))) stop("Invalid metadata keys",call.=FALSE)
  get<-function(k) {
    i<-match(k,keys)
    if(is.na(i)) stop("Missing metadata key: ",k,call.=FALSE)
    v<-as.character(metadata$value[[i]])
    if(is.na(v)) "" else v
  }
  if(!identical(get("review_id"),review_id)) stop("Review identity mismatch",call.=FALSE)
  if(!grepl("^[0-9]+$",run_id)) stop("Invalid run ID",call.=FALSE)
  previous<-get("latest_w00_run_id")
  status<-tolower(get("latest_w00_status"))
  active<-status %in% c("queued","pending","running","in_progress")
  if(action=="start") {
    if(active && nzchar(previous) && previous!=run_id)
      stop("Another review W00 run is active",call.=FALSE)
    return(list(status="running",event_id=paste0("W00:",run_id,":started")))
  }
  if(!identical(previous,run_id)) stop("Refusing stale or unrelated review run",call.=FALSE)
  if(action=="success") {
    if(!status %in% c("running","in_progress","success"))
      stop("Cannot publish from inactive or failed state",call.=FALSE)
    if(!grepl("^[0-9]+$",record_id)) stop("Missing Zenodo record",call.=FALSE)
    return(list(status="success",event_id=paste0("W00:",run_id,":zenodo_published")))
  }
  if(action=="failure") {
    if(identical(status,"success")) stop("Cannot downgrade published success",call.=FALSE)
    return(list(status="failed",event_id=paste0("W00:",run_id,":failed")))
  }
  stop("Unknown W00 transition action",call.=FALSE)
}
