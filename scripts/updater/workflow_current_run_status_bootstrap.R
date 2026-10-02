#!/usr/bin/env Rscript
suppressPackageStartupMessages(library(jsonlite))

args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag,default=NULL){
  i<-match(flag,args)
  if(is.na(i)) return(default)
  if(i==length(args)) stop(sprintf("Missing value after %s",flag),call.=FALSE)
  args[[i+1L]]
}

status_path <- arg("--status","docs/current_run/current_run_status.json")
w01_pointer <- arg("--w01-pointer","docs/deduplication/zenodo/run-36971418284.json")
w08_registry <- arg("--w08-registry","docs/workflow08/zenodo_registry.csv")
search_state <- arg("--search-state","docs/search_record/state/current.json")

if(!file.exists(w01_pointer)) stop("W01 pointer not found",call.=FALSE)
if(!file.exists(w08_registry)) stop("W08 registry not found",call.=FALSE)
if(!file.exists(search_state)) stop("W00 state not found",call.=FALSE)

w01 <- fromJSON(w01_pointer,simplifyVector=FALSE)
if(!identical(as.character(w01$status),"published") || !as.character(w01$state) %in% c("delta","final")) {
  stop("W01 pointer is not a published final/delta state",call.=FALSE)
}

reg <- read.csv(w08_registry,stringsAsFactors=FALSE,check.names=FALSE)
hit <- reg[as.character(reg$status)=="authoritative",,drop=FALSE]
if(nrow(hit)!=1L) stop("Expected exactly one authoritative W08 row",call.=FALSE)
w08_pointer <- sprintf("docs/workflow08/zenodo/run-%s.json",as.character(hit$source_run_id[[1L]]))
if(!file.exists(w08_pointer)) stop("Authoritative W08 pointer not found",call.=FALSE)
w08 <- fromJSON(w08_pointer,simplifyVector=FALSE)

w00 <- fromJSON(search_state,simplifyVector=FALSE)
state_id <- as.character(w00$state_id)
m <- regexpr("[0-9]{4}-[0-9]{2}-[0-9]{2}",state_id)
last_search_date <- if(m[[1L]]>0L) regmatches(state_id,m) else ""

progress <- setNames(lapply(c("W00","W01","W02","W03","W04","W05","W06","W07","W08","W10"),function(x)list(status="pending")),
                     c("W00","W01","W02","W03","W04","W05","W06","W07","W08","W10"))
progress$W00$status <- "complete"
progress$W01$status <- "complete"
progress$W02$status <- "active"
progress$current_stage <- "W01"
progress$completed_through <- 2L
progress$active_position <- 3L
progress$status_label <- "Deduplication complete; Workflow 02 enrichment in progress"

x <- list(
  schema="living-evidence-map-current-run-status-v1",
  update_id=paste0("w01-run-",as.character(w01$github_run_id)),
  branch="workflow01-final-architecture",
  started_at_utc=as.character(w01$published_at_utc),
  last_updated_at_utc=format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ"),
  baseline=list(
    workflow08_pointer=w08_pointer,
    workflow08_source_run_id=as.character(w08$source_github_run_id),
    canonical_records=as.integer(w08$canonical_records),
    canonical_sha256=as.character(w08$final_canonical_jsonl_sha256)
  ),
  search=list(
    workflow00_run_id="",
    search_date=last_search_date,
    search_results=as.integer(w01$source_manifestations),
    sources=list()
  ),
  cohort=list(
    record_ids_path="docs/current_run/current_run_record_ids.txt",
    record_ids_sha256=NULL,
    deduplicated_records=NULL
  ),
  counts=list(
    search_results=as.integer(w01$source_manifestations),
    deduplicated_records=as.integer(w01$canonical_records),
    enriched_records=NULL,
    retraction_exclusions=NULL,
    screened_include=NULL,
    screened_exclude=NULL,
    geography=list(with=NULL,without=NULL),
    topics=list(with=NULL,without=NULL)
  ),
  progress=progress,
  workflow_runs=list(W01=as.character(w01$github_run_id))
)

dir.create(dirname(status_path),recursive=TRUE,showWarnings=FALSE)
writeLines(toJSON(x,auto_unbox=TRUE,pretty=TRUE,null="null",na="null",digits=NA),status_path,useBytes=TRUE)
cat(sprintf("PASS: bootstrapped current-run status from W01 run %s (%d search results -> %d canonical records)\n",
            w01$github_run_id,as.integer(w01$source_manifestations),as.integer(w01$canonical_records)))
