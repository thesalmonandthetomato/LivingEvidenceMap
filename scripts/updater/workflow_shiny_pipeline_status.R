#!/usr/bin/env Rscript
suppressPackageStartupMessages({
  library(googlesheets4)
  library(digest)
})

args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag,default=NULL){
  i<-match(flag,args)
  if(is.na(i)) return(default)
  if(i==length(args)) stop(sprintf("Missing value after %s",flag),call.=FALSE)
  args[[i+1L]]
}
blank_to_na <- function(x){
  if(is.null(x)||!nzchar(trimws(as.character(x)))) return(NA_character_)
  as.character(x)
}

update_id <- arg("--update-id")
stage <- arg("--stage")
workflow_run_id <- arg("--workflow-run-id",Sys.getenv("GITHUB_RUN_ID",""))
last_search_date <- blank_to_na(arg("--last-search-date",""))
canonical_existing <- blank_to_na(arg("--canonical-existing",""))
search_results_total <- blank_to_na(arg("--search-results-total",""))
deduplicated_records <- blank_to_na(arg("--deduplicated-records",""))
enriched_records <- blank_to_na(arg("--enriched-records",""))
retracted_records <- blank_to_na(arg("--retracted-records",""))
screened_include <- blank_to_na(arg("--screened-include",""))
screened_exclude <- blank_to_na(arg("--screened-exclude",""))
geography_with <- blank_to_na(arg("--geography-with",""))
geography_without <- blank_to_na(arg("--geography-without",""))
topic_with <- blank_to_na(arg("--topic-with",""))
topic_without <- blank_to_na(arg("--topic-without",""))
completed_through <- blank_to_na(arg("--completed-through",""))
active_workflow <- blank_to_na(arg("--active-workflow",""))
status_label <- blank_to_na(arg("--status-label",""))
sheet_id <- arg("--sheet-id",Sys.getenv("LEM_GOOGLE_SHEET_ID"))
credential <- arg("--credential",Sys.getenv("LEM_GOOGLE_SERVICE_ACCOUNT_JSON"))
tab <- arg("--tab","pipeline_run_status")

if(is.null(update_id)||!nzchar(update_id)) stop("--update-id is required",call.=FALSE)
if(is.null(stage)||!nzchar(stage)) stop("--stage is required",call.=FALSE)
if(is.null(sheet_id)||!nzchar(sheet_id)||is.null(credential)||!file.exists(credential)) stop("Google Sheet credential/id missing",call.=FALSE)

cols <- c(
  "event_id","update_id","event_at_utc","stage","workflow_run_id",
  "last_search_date","canonical_existing","search_results_total",
  "deduplicated_records","enriched_records","retracted_records",
  "screened_include","screened_exclude",
  "geography_with","geography_without","topic_with","topic_without",
  "completed_through","active_workflow","status_label"
)

gs4_auth(path=credential,cache=FALSE)
tabs <- sheet_names(sheet_id)
if(!tab %in% tabs){
  sheet_add(sheet_id,sheet=tab)
  empty <- as.data.frame(setNames(replicate(length(cols),character(),simplify=FALSE),cols),stringsAsFactors=FALSE)
  sheet_write(empty,ss=sheet_id,sheet=tab)
}
x <- read_sheet(sheet_id,sheet=tab,col_types="c")
if(nrow(x)){
  miss <- setdiff(cols,names(x))
  if(length(miss)) stop("pipeline_run_status missing columns: ",paste(miss,collapse=", "),call.=FALSE)
  prev <- x[as.character(x$update_id)==update_id,,drop=FALSE]
  latest <- if(nrow(prev)) prev[nrow(prev),,drop=FALSE] else NULL
} else latest <- NULL

incoming <- list(
  last_search_date=last_search_date,
  canonical_existing=canonical_existing,
  search_results_total=search_results_total,
  deduplicated_records=deduplicated_records,
  enriched_records=enriched_records,
  retracted_records=retracted_records,
  screened_include=screened_include,
  screened_exclude=screened_exclude,
  geography_with=geography_with,
  geography_without=geography_without,
  topic_with=topic_with,
  topic_without=topic_without,
  completed_through=completed_through,
  active_workflow=active_workflow,
  status_label=status_label
)
value <- function(nm){
  z <- incoming[[nm]]
  if(!is.na(z)) return(z)
  if(!is.null(latest)){
    p <- as.character(latest[[nm]][[1L]])
    if(!is.na(p) && nzchar(p)) return(p)
  }
  ""
}

now <- format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ")
event_id <- paste0("pipeline-status-",substr(digest(paste(update_id,stage,workflow_run_id,now,sep="|"),algo="sha256",serialize=FALSE),1,24))
row <- data.frame(
  event_id=event_id,update_id=update_id,event_at_utc=now,stage=stage,
  workflow_run_id=as.character(workflow_run_id),
  last_search_date=value("last_search_date"),
  canonical_existing=value("canonical_existing"),
  search_results_total=value("search_results_total"),
  deduplicated_records=value("deduplicated_records"),
  enriched_records=value("enriched_records"),
  retracted_records=value("retracted_records"),
  screened_include=value("screened_include"),
  screened_exclude=value("screened_exclude"),
  geography_with=value("geography_with"),
  geography_without=value("geography_without"),
  topic_with=value("topic_with"),
  topic_without=value("topic_without"),
  completed_through=value("completed_through"),
  active_workflow=value("active_workflow"),
  status_label=value("status_label"),
  stringsAsFactors=FALSE
)
sheet_append(sheet_id,data=row,sheet=tab)
verify <- read_sheet(sheet_id,sheet=tab,col_types="c")
if(sum(as.character(verify$event_id)==event_id)!=1L) stop("pipeline status write verification failed",call.=FALSE)
cat(sprintf("PASS: pipeline status update=%s stage=%s event=%s\n",update_id,stage,event_id))
