#!/usr/bin/env Rscript
suppressPackageStartupMessages({
  library(googlesheets4)
  library(jsonlite)
  library(digest)
})

args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag,default=NULL){i<-match(flag,args);if(is.na(i))return(default);if(i==length(args))stop(sprintf("Missing value after %s",flag),call.=FALSE);args[[i+1L]]}
`%||%` <- function(x,y) if(is.null(x)||length(x)==0L) y else x

queue_path <- arg("--queue")
batch_id <- arg("--batch-id")
queue_sha <- tolower(arg("--queue-sha256",""))
sheet_id <- arg("--sheet-id",Sys.getenv("LEM_GOOGLE_SHEET_ID"))
credential <- arg("--credential",Sys.getenv("LEM_GOOGLE_SERVICE_ACCOUNT_JSON"))
output <- arg("--output")
manifest_path <- arg("--manifest")

req <- c(queue_path,batch_id,queue_sha,sheet_id,credential,output,manifest_path)
if(any(vapply(req,function(x)is.null(x)||!nzchar(x),logical(1)))) stop("Missing required W08 Shiny export argument",call.=FALSE)
if(!file.exists(queue_path)||!file.exists(credential)) stop("Required W08 Shiny export file missing",call.=FALSE)

lines <- readLines(queue_path,warn=FALSE,encoding="UTF-8")
lines <- lines[nzchar(trimws(lines))]
if(!length(lines)) stop("W08 queue is empty",call.=FALSE)
actual_sha <- digest(file=queue_path,algo="sha256",serialize=FALSE)
if(tolower(actual_sha)!=queue_sha) stop("W08 queue SHA mismatch",call.=FALSE)
cases <- lapply(lines,fromJSON,simplifyVector=FALSE)
record_ids <- vapply(cases,function(z)as.character(z$record_id %||% ""),character(1))
if(any(!nzchar(record_ids))||anyDuplicated(record_ids)) stop("W08 queue record identity invariant failed",call.=FALSE)
case_sha <- setNames(vapply(lines,function(z)digest(z,algo="sha256",serialize=FALSE),character(1)),record_ids)

gs4_auth(path=credential,cache=FALSE)
tabs <- sheet_names(sheet_id)
if(!"queue_w08_active"%in%tabs || !"decisions_w08"%in%tabs) stop("W08 Shiny queue/decision tab missing",call.=FALSE)
q <- read_sheet(sheet_id,sheet="queue_w08_active",col_types="c")
if(!nrow(q)) stop("W08 active queue tab is empty",call.=FALSE)
if(length(unique(q$batch_id))!=1L || as.character(unique(q$batch_id)[[1L]])!=batch_id) stop("W08 active batch ID mismatch",call.=FALSE)
if(length(unique(q$queue_sha256))!=1L || tolower(as.character(unique(q$queue_sha256)[[1L]]))!=queue_sha) stop("W08 active queue SHA metadata mismatch",call.=FALSE)

d <- read_sheet(sheet_id,sheet="decisions_w08",col_types="c")
required <- c("decision_id","record_id","queue_sha256","record_case_sha256","issue_decisions_json","reviewer","resolved_at_utc")
if(!all(required%in%names(d))) stop("W08 decision tab schema mismatch",call.=FALSE)
d <- d[tolower(as.character(d$queue_sha256))==queue_sha,,drop=FALSE]
if(!nrow(d)) stop("No W08 Shiny decisions for active queue",call.=FALSE)
d <- d[order(as.character(d$resolved_at_utc),seq_len(nrow(d)),decreasing=TRUE),,drop=FALSE]
active <- d[!duplicated(as.character(d$record_id)),,drop=FALSE]
active <- active[match(record_ids,as.character(active$record_id)),,drop=FALSE]
if(any(is.na(active$record_id))) stop("W08 Shiny decisions are incomplete",call.=FALSE)

all_out <- list()
for(i in seq_along(cases)){
  rec <- cases[[i]]
  rid <- record_ids[[i]]
  if(tolower(as.character(active$record_case_sha256[[i]]))!=tolower(case_sha[[rid]])) stop("W08 record-case SHA mismatch for ",rid,call.=FALSE)
  got <- fromJSON(as.character(active$issue_decisions_json[[i]]),simplifyVector=FALSE)
  if(!is.list(got)) stop("W08 issue_decisions_json malformed for ",rid,call.=FALSE)
  expected <- rec$issues %||% list()
  if(length(got)!=length(expected)) stop("W08 issue decision count mismatch for ",rid,call.=FALSE)
  got_keys <- vapply(got,function(z)as.character(z$review_key %||% ""),character(1))
  if(any(!nzchar(got_keys))||anyDuplicated(got_keys)) stop("W08 issue decision keys invalid for ",rid,call.=FALSE)

  for(issue in expected){
    typ <- as.character(issue$issue_type %||% "")
    key <- paste(rid,typ,sep="::")
    j <- match(key,got_keys)
    if(is.na(j)) stop("Missing W08 decision for ",key,call.=FALSE)
    z <- got[[j]]
    allowed <- as.character(issue$allowed_human_outcomes %||% character())
    decision <- as.character(z$decision %||% "")
    if(!decision%in%allowed) stop("Invalid W08 decision for ",key,call.=FALSE)
    if(as.character(z$record_id %||% "")!=rid || as.character(z$issue_type %||% "")!=typ) stop("W08 decision identity mismatch for ",key,call.=FALSE)
    if(tolower(as.character(z$issue_state_sha256 %||% ""))!=tolower(as.character(issue$issue_state_sha256 %||% ""))) stop("W08 issue-state SHA mismatch for ",key,call.=FALSE)
    if(tolower(as.character(z$queue_sha256 %||% ""))!=queue_sha) stop("W08 decision queue SHA mismatch for ",key,call.=FALSE)
    all_out[[length(all_out)+1L]] <- z
  }
}

dir.create(dirname(output),recursive=TRUE,showWarnings=FALSE)
con <- file(output,"wt",encoding="UTF-8")
for(z in all_out) writeLines(toJSON(z,auto_unbox=TRUE,null="null",na="null",digits=NA),con,useBytes=TRUE)
close(con)
out_sha <- digest(file=output,algo="sha256",serialize=FALSE)
manifest <- list(
  schema="living-evidence-map-workflow08-shiny-export-v1",
  status="PASS",
  batch_id=batch_id,
  queue_sha256=queue_sha,
  records=length(cases),
  issues=length(all_out),
  decisions_sha256=out_sha,
  exported_at_utc=format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ")
)
writeLines(toJSON(manifest,auto_unbox=TRUE,pretty=TRUE),manifest_path,useBytes=TRUE)
cat(sprintf("PASS: exported W08 Shiny decisions: records=%d issues=%d sha=%s\n",length(cases),length(all_out),out_sha))
