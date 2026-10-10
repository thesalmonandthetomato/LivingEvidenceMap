#!/usr/bin/env Rscript
# Prepare an immutable-per-run query archive BEFORE API execution; no network operations.
suppressPackageStartupMessages({library(jsonlite);library(digest)})
args<-commandArgs(trailingOnly=TRUE)
arg<-function(flag,default=NULL){i<-match(flag,args);if(is.na(i))return(default);if(i==length(args))stop(paste("Missing",flag),call.=FALSE);args[[i+1L]]}
plan_path<-arg("--plan")
strategy_path<-arg("--strategy")
archive_root<-arg("--archive-root","docs/search_archive")
run_id<-arg("--run-id")
if(is.null(plan_path)||!file.exists(plan_path)||is.null(strategy_path)||!file.exists(strategy_path))stop("W00 archive requires an existing --plan and --strategy",call.=FALSE)
if(is.null(run_id)||!grepl("^[A-Za-z0-9_-]+$",run_id))stop("W00 archive requires a safe --run-id",call.=FALSE)
plan<-fromJSON(plan_path,simplifyVector=FALSE)
queries<-plan$source_queries
if(is.null(queries)||!length(queries))stop("W00 archive: no translated database queries in plan",call.=FALSE)
target<-file.path(archive_root,paste0("run-",run_id))
if(dir.exists(target)||file.exists(target))stop(sprintf("W00 archive already exists (immutable): %s",target),call.=FALSE)
dir.create(target,recursive=TRUE,showWarnings=FALSE)
if(!isTRUE(file.copy(strategy_path,file.path(target,"source_strategy.json"))))stop("W00 archive failed to copy strategy",call.=FALSE)
items<-list()
for(name in names(queries)){
  if(!grepl("^[A-Za-z0-9_-]+$",name))stop(sprintf("W00 archive: invalid source key: %s",name),call.=FALSE)
  q<-as.character(queries[[name]])
  if(length(q)!=1L||!nzchar(trimws(q)))stop(sprintf("W00 archive: source %s has empty query",name),call.=FALSE)
  p<-file.path(target,paste0(name,".txt"))
  writeLines(q,p,useBytes=TRUE)
  items[[name]]<-list(file=basename(p),sha256=digest(file=p,algo="sha256",serialize=FALSE),query_string_sha256=digest(q,algo="sha256",serialize=FALSE),status="prepared_not_executed")
}
manifest<-list(schema="w00-query-archive-v1",run_id=run_id,source_strategy=basename(strategy_path),strategy_sha256=digest(file=strategy_path,algo="sha256",serialize=FALSE),search_version=plan$search_version,run_type=plan$run_type,created_at=format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ"),translation=if(is.null(plan$translation))"legacy-orchestrator-v1" else plan$translation,queries=items,execution_report_status="not_yet_available")
writeLines(toJSON(manifest,auto_unbox=TRUE,pretty=TRUE,null="null"),file.path(target,"manifest.json"),useBytes=TRUE)
message(sprintf("Prepared W00 query archive: %s",target))
