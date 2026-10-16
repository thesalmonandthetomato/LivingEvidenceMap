#!/usr/bin/env Rscript
# Publish a completed Shiny-launched W04 experiment without modifying the
# production W04 state or replacing another experiment's resolution queue.
suppressPackageStartupMessages({library(jsonlite);library(digest);library(googlesheets4)})
args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag,default=NULL) {i<-match(flag,args);if(is.na(i))return(default);if(i==length(args))stop("Missing ",flag,call.=FALSE);args[[i+1L]]}
`%||%` <- function(x,y) if(is.null(x)||!length(x)) y else x
manifest_path <- arg("--input-manifest")
merged_path <- arg("--merged")
resolution_path <- arg("--resolution-queue","")
resolution_manifest_path <- arg("--resolution-manifest","")
sheet_id <- arg("--sheet-id","")
credential <- arg("--credential")
run_id <- arg("--run-id")
if(any(vapply(list(manifest_path,merged_path,credential,run_id),is.null,logical(1))))
  stop("Required Shiny W04 publisher argument missing",call.=FALSE)
if(!grepl("^[0-9]+$",run_id) || !file.exists(credential))stop("Invalid run ID or credential",call.=FALSE)
manifest <- fromJSON(manifest_path,simplifyVector=FALSE)
review_id <- as.character(manifest$review_id %||% "")
manifest_sheet <- as.character(manifest$review_sheet_id %||% "")
if(!grepl("^[A-Za-z0-9_-]{20,160}$",manifest_sheet))stop("Missing immutable review sheet identity",call.=FALSE)
if(nzchar(sheet_id) && !identical(sheet_id,manifest_sheet))stop("W04 model return sheet does not match Shiny review metadata",call.=FALSE)
sheet_id <- manifest_sheet
subset_id <- as.character(manifest$subset_id %||% "")
prompt_sha <- as.character(manifest$prompt_sha256 %||% "")
if(!identical(as.character(manifest$schema),"lem-w04-shiny-subset-restoration-v1") ||
   !grepl("^w04-subset-[0-9a-f]{20}$",subset_id) ||
   !grepl("^[0-9a-f]{64}$",prompt_sha) || !nzchar(review_id))
  stop("Invalid Shiny subset input provenance",call.=FALSE)
lines <- readLines(merged_path,warn=FALSE,encoding="UTF-8")
lines <- lines[nzchar(trimws(lines))]
if(!length(lines))stop("No merged model results to publish",call.=FALSE)
records <- lapply(lines,fromJSON,simplifyVector=FALSE)
scalar <- function(x) as.character(x %||% "")
ids <- vapply(records,function(r)scalar(r$record_id),character(1))
decisions <- vapply(records,function(r)scalar((r$screening %||% list())$decision),character(1))
shas <- vapply(records,function(r)scalar((r$screening %||% list())$prompt_sha256),character(1))
if(any(!nzchar(ids))||anyDuplicated(ids)||any(!decisions%in%c("retain","exclude","uncertain")) ||
   any(shas!=prompt_sha)||length(ids)!=as.integer(manifest$record_count))
  stop("W04 model result identity/decision/prompt invariant failed",call.=FALSE)
model_sha <- digest(file=merged_path,algo="sha256",serialize=FALSE)
result_tab <- paste0("w04_model_results_",run_id)
queue_tab <- paste0("queue_w04_resolution_",run_id)
index_tab <- "w04_model_batch_registry"
queue_sha <- ""
queue_rows <- NULL
if(any(decisions=="uncertain")) {
  if(!nzchar(resolution_path)||!nzchar(resolution_manifest_path))
    stop("Uncertain W04 results require a resolution queue",call.=FALSE)
  qm <- fromJSON(resolution_manifest_path,simplifyVector=FALSE)
  qlines <- readLines(resolution_path,warn=FALSE,encoding="UTF-8")
  qlines <- qlines[nzchar(trimws(qlines))]
  queue_sha <- digest(file=resolution_path,algo="sha256",serialize=FALSE)
  cases <- lapply(qlines,fromJSON,simplifyVector=FALSE)
  qids <- vapply(cases,function(x)scalar(x$record_id),character(1))
  if(!identical(queue_sha,scalar(qm$queue_sha256)) ||
     !identical(scalar(qm$source_run_id),run_id) ||
     !setequal(qids,ids[decisions=="uncertain"])||anyDuplicated(qids))
    stop("W04 uncertainty queue provenance or coverage mismatch",call.=FALSE)
  batch_id <- paste0("w04-resolution-",run_id,"-",substr(queue_sha,1L,12L))
  queue_rows <- data.frame(batch_id=batch_id,queue_sha256=queue_sha,
    case_index=as.character(seq_along(qlines)),
    review_case_id=vapply(cases,function(x)scalar(x$review_case_id),character(1)),
    case_json=qlines,review_mode=c("resolution",rep("",length(qlines)-1L)),
    source_run_id=c(run_id,rep("",length(qlines)-1L)),stringsAsFactors=FALSE)
}
if(identical(arg("--dry-run","false"),"true")) {
  cat(sprintf("PASS dry-run: run %s, review %s, sheet %s, %d results, %d uncertain\\n",
    run_id,review_id,sheet_id,length(ids),sum(decisions=="uncertain")))
  quit(save="no",status=0L)
}
gs4_auth(path=credential,cache=FALSE)
tabs <- sheet_names(sheet_id)
if(index_tab%in%tabs) {
  existing <- as.data.frame(read_sheet(sheet_id,sheet=index_tab,col_types="c"))
  if(nrow(existing)&&"run_id"%in%names(existing) && run_id%in%as.character(existing$run_id)) {
    row <- existing[as.character(existing$run_id)==run_id,,drop=FALSE]
    if(nrow(row)!=1L||!identical(as.character(row$model_sha256[[1L]]),model_sha))
      stop("Existing W04 run has incompatible published content",call.=FALSE)
    cat("PASS: identical W04 model batch already published: ",run_id,"\n",sep="")
    quit(save="no",status=0L)
  }
}
if(any(c(result_tab,if(!is.null(queue_rows))queue_tab else character())%in%tabs))
  stop("Unregistered W04 model result tab already exists; refusing overwrite",call.=FALSE)
results <- data.frame(run_id=run_id,subset_id=subset_id,record_id=ids,
  decision=decisions,prompt_sha256=shas,result_json=lines,stringsAsFactors=FALSE)
sheet_write(results,ss=sheet_id,sheet=result_tab)
verified <- as.data.frame(read_sheet(sheet_id,sheet=result_tab,col_types="c"))
if(nrow(verified)!=length(ids) ||
   !identical(as.character(verified$record_id),ids) ||
   !identical(as.character(verified$decision),decisions))
  stop("W04 model result publication verification failed",call.=FALSE)
if(!is.null(queue_rows)) {
  sheet_write(queue_rows,ss=sheet_id,sheet=queue_tab)
  qverify <- as.data.frame(read_sheet(sheet_id,sheet=queue_tab,col_types="c"))
  actual <- digest(paste0(paste(qverify$case_json,collapse="\n"),"\n"),algo="sha256",serialize=FALSE)
  if(!identical(actual,queue_sha))stop("W04 published uncertainty queue SHA mismatch",call.=FALSE)
}
registry_row <- data.frame(review_id=review_id,run_id=run_id,subset_id=subset_id,
  prompt_version_id=scalar(manifest$prompt_version_id),
  prompt_sha256=prompt_sha,model_sha256=model_sha,
  result_tab=result_tab,resolution_tab=if(is.null(queue_rows))"" else queue_tab,
  resolution_queue_sha256=queue_sha,
  total=as.character(length(ids)),retain=as.character(sum(decisions=="retain")),
  exclude=as.character(sum(decisions=="exclude")),
  uncertain=as.character(sum(decisions=="uncertain")),
  published_at_utc=format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ"),
  stringsAsFactors=FALSE)
if(!index_tab%in%sheet_names(sheet_id)) {
  sheet_write(registry_row,ss=sheet_id,sheet=index_tab)
} else {
  sheet_append(ss=sheet_id,data=registry_row,sheet=index_tab)
}
idx <- as.data.frame(read_sheet(sheet_id,sheet=index_tab,col_types="c"))
if(sum(as.character(idx$run_id)==run_id)!=1L)
  stop("W04 model batch registry publication not verified",call.=FALSE)
cat(sprintf("PASS: W04 model batch %s; %d records; %d uncertain; tab %s\n",
  run_id,length(ids),sum(decisions=="uncertain"),result_tab))
