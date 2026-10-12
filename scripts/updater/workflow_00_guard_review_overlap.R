#!/usr/bin/env Rscript
# Shiny W00 overlap guard: review-specific metadata only, never repository status.
args <- commandArgs(trailingOnly=TRUE)
get_arg <- function(k,default="") {
  i <- match(k,args)
  if(is.na(i)) return(default)
  if(i==length(args)) stop("Missing ",k,call.=FALSE)
  args[[i+1L]]
}
csv <- get_arg("--metadata-csv")
sheet <- get_arg("--sheet-id")
if(nzchar(csv)==nzchar(sheet)) stop("Provide exactly one metadata source",call.=FALSE)
if(nzchar(csv)) {
  d <- read.csv(csv,stringsAsFactors=FALSE,check.names=FALSE)
} else {
  if(!requireNamespace("googlesheets4",quietly=TRUE)) stop("Missing googlesheets4",call.=FALSE)
  credential <- get_arg("--credential")
  if(!nzchar(credential)||!file.exists(credential)) stop("Missing credentials",call.=FALSE)
  googlesheets4::gs4_auth(path=credential,cache=FALSE)
  d <- tryCatch(as.data.frame(googlesheets4::read_sheet(sheet,sheet="review_metadata")),
    error=function(e) stop("Review metadata unavailable: ",conditionMessage(e),call.=FALSE))
}
if(!all(c("key","value")%in%names(d))) stop("Invalid review metadata columns",call.=FALSE)
keys <- trimws(as.character(d$key))
if(anyNA(keys)||anyDuplicated(keys)||any(!nzchar(keys))) stop("Invalid metadata keys",call.=FALSE)
get <- function(k) {
  i <- match(k,keys)
  if(is.na(i)) return("")
  value <- d$value[[i]]
  if(length(value)!=1L || is.na(value)) return("")
  trimws(as.character(value))
}
if(!grepl("^[A-Za-z0-9][A-Za-z0-9._-]{3,127}$",get("review_id")))
  stop("Missing review_id",call.=FALSE)
status <- tolower(get("latest_w00_status"))
id <- get("latest_w00_run_id")
supersede <- identical(tolower(get_arg("--supersede")),"true")
resume <- get_arg("--resume-run-id")
if(nzchar(id) && !grepl("^[0-9]+$",id)) {
  if(status %in% c("queued","in_progress","running","pending"))
    stop("Active W00 status has an invalid run ID; refusing overlap",call.=FALSE)
  warning("Ignoring non-numeric historical run ID for an inactive W00 review",call.=FALSE)
  id <- ""
}
if(nzchar(resume) && !grepl("^[0-9]+$",resume)) stop("Invalid resume run ID",call.=FALSE)
if(!status %in% c("","queued","in_progress","running","pending","completed","success","failure","failed","cancelled","skipped","timed_out"))
  stop("Unknown review-specific W00 status",call.=FALSE)
if(status %in% c("queued","in_progress","running","pending")) {
  if(!nzchar(id)) stop("Active W00 status without run ID",call.=FALSE)
  if(nzchar(resume) && identical(resume,id)) {
    cat("PASS: explicit resume of matching review W00 run\n")
  } else if(supersede) {
    cat("PASS: explicit supersede of incomplete review W00 run\n")
  } else {
    stop("Review W00 run ",id," is incomplete; refuse overlapping search",call.=FALSE)
  }
} else if(nzchar(resume)) {
  stop("Cannot resume review W00: no matching incomplete run",call.=FALSE)
} else {
  cat("PASS: no incomplete W00 for this review\n")
}
