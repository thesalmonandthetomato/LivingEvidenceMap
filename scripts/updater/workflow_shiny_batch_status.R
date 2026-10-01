#!/usr/bin/env Rscript
suppressPackageStartupMessages({
  library(googlesheets4)
  library(digest)
})

args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag, default=NULL) {
  i <- match(flag,args)
  if (is.na(i)) return(default)
  if (i == length(args)) stop(sprintf("Missing value after %s",flag),call.=FALSE)
  args[[i+1L]]
}

stage <- arg("--stage")
batch_id <- arg("--batch-id")
queue_sha256 <- arg("--queue-sha256")
status <- arg("--status")
sheet_id <- arg("--sheet-id",Sys.getenv("LEM_GOOGLE_SHEET_ID"))
credential <- arg("--credential",Sys.getenv("LEM_GOOGLE_SERVICE_ACCOUNT_JSON"))
workflow_run_id <- arg("--workflow-run-id",Sys.getenv("GITHUB_RUN_ID",""))
source_run_id <- arg("--source-run-id","")
output_sha256 <- arg("--output-sha256","")
message <- arg("--message","")
tab <- arg("--tab","workflow_batch_status")

allowed_stages <- c("01","02","04","08")
allowed_status <- c("published","review_complete","consumed")
if(is.null(stage)||!stage %in% allowed_stages) stop("Invalid --stage",call.=FALSE)
if(is.null(batch_id)||!nzchar(batch_id)) stop("--batch-id is required",call.=FALSE)
if(is.null(queue_sha256)||!grepl("^[0-9a-fA-F]{64}$",queue_sha256)) stop("--queue-sha256 must be a SHA-256",call.=FALSE)
if(is.null(status)||!status %in% allowed_status) stop("Invalid --status",call.=FALSE)
if(is.null(sheet_id)||!nzchar(sheet_id)||is.null(credential)||!nzchar(credential)||!file.exists(credential)) stop("Google Sheet credential/id missing",call.=FALSE)

gs4_auth(path=credential,cache=FALSE)
tabs <- sheet_names(sheet_id)
cols <- c(
  "event_id","stage","batch_id","queue_sha256","status","event_at_utc",
  "workflow_run_id","source_run_id","output_sha256","message"
)
if(!tab %in% tabs){
  sheet_add(sheet_id,sheet=tab)
  empty <- as.data.frame(setNames(replicate(length(cols),character(),simplify=FALSE),cols),stringsAsFactors=FALSE)
  sheet_write(empty,ss=sheet_id,sheet=tab)
}

x <- read_sheet(sheet_id,sheet=tab,col_types="c")
if(nrow(x)){
  missing <- setdiff(cols,names(x))
  if(length(missing)) stop("Batch-status tab missing required columns: ",paste(missing,collapse=", "),call.=FALSE)
  hits <- x[
    as.character(x$stage)==stage &
    as.character(x$batch_id)==batch_id &
    as.character(x$queue_sha256)==queue_sha256,
    ,drop=FALSE
  ]
} else hits <- x

latest_status <- ""
if(nrow(hits)) latest_status <- as.character(hits$status[[nrow(hits)]])

if(status=="review_complete" && nzchar(latest_status) && !latest_status %in% c("published","review_complete")) {
  stop(sprintf("Cannot mark review_complete from latest status %s",latest_status),call.=FALSE)
}
if(status=="consumed" && !latest_status %in% c("review_complete","consumed")) {
  stop(sprintf("Cannot mark consumed before review_complete; latest status is %s",ifelse(nzchar(latest_status),latest_status,"<none>")),call.=FALSE)
}

event_at <- format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ")
event_id <- paste0(
  "batch-status-",
  substr(digest(paste(stage,batch_id,queue_sha256,status,event_at,workflow_run_id,sep="|"),algo="sha256",serialize=FALSE),1,24)
)
row <- data.frame(
  event_id=event_id,
  stage=stage,
  batch_id=batch_id,
  queue_sha256=tolower(queue_sha256),
  status=status,
  event_at_utc=event_at,
  workflow_run_id=as.character(workflow_run_id),
  source_run_id=as.character(source_run_id),
  output_sha256=tolower(as.character(output_sha256)),
  message=as.character(message),
  stringsAsFactors=FALSE
)
sheet_append(sheet_id,data=row,sheet=tab)

verify <- read_sheet(sheet_id,sheet=tab,col_types="c")
v <- verify[as.character(verify$event_id)==event_id,,drop=FALSE]
if(nrow(v)!=1L) stop("Batch-status write verification failed",call.=FALSE)
cat(sprintf("PASS: W%s batch %s status=%s queue=%s\n",stage,batch_id,status,queue_sha256))
