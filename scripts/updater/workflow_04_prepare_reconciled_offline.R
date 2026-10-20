#!/usr/bin/env Rscript
# Offline adapter only: convert an already reconciled, COMPLETE canonical-ID
# decision layer to inputs for the unchanged W04 incremental merge.
# Never publishes, dispatches GitHub workflows, or calls an LLM.
suppressPackageStartupMessages({library(jsonlite);library(digest)})
args <- commandArgs(trailingOnly=TRUE)
arg <- function(k) {i<-match(k,args);if(is.na(i)||i==length(args))stop("Missing ",k);args[[i+1L]]}
canonical_path <- arg("--canonical")
w03_path <- arg("--workflow03-status")
reconciled_path <- arg("--reconciled")
output <- arg("--output-dir")
`%||%` <- function(x,y)if(is.null(x)||!length(x))y else x
readj <- function(path) {
  if(!file.exists(path))stop("Input missing: ",path)
  xs <- readLines(path,warn=FALSE,encoding="UTF-8")
  lapply(xs[nzchar(trimws(xs))],jsonlite::fromJSON,simplifyVector=FALSE)
}
val <- function(x) {z<-as.character(x);if(length(z)!=1L||is.na(z))return("");z}
canon <- readj(canonical_path); w03 <- readj(w03_path); src <- readj(reconciled_path)
ci <- vapply(canon,function(x)val(x$identity$record_id),character(1))
wi <- vapply(w03,function(x)val(x$record_id),character(1))
ri <- vapply(src,function(x)val(x$record_id),character(1))
if(any(!nzchar(ci))||anyDuplicated(ci)||any(!nzchar(wi))||anyDuplicated(wi)||
   !setequal(ci,wi)||any(!nzchar(ri))||anyDuplicated(ri))
  stop("Canonical, W03 or reconciliation identity invariant failed")
wmap <- setNames(w03,wi)
excluded <- vapply(ci,function(id) {
  x<-wmap[[id]]
  isTRUE((x$publication_status %||% list())$exclude_from_workflow04 %||%
    x$exclude_from_workflow04 %||% FALSE)
},logical(1))
eligible <- sort(ci[!excluded])
if(!setequal(ri,eligible)||length(ri)!=length(eligible))
  stop("Reconciliation does not exactly cover eligible canonical IDs")
m <- setNames(src,ri)
rows <- lapply(eligible,function(id) {
  z<-m[[id]]
  if(!identical(val(z$status),"resolved") ||
     !val(z$decision)%in%c("retain","exclude"))
    stop("Unresolved or conflicting decision for ",id)
  model <- z$model_result_json
  if(!is.null(model)&&nzchar(val(model))) {
    row<-jsonlite::fromJSON(val(model),simplifyVector=FALSE)
    if(!identical(val(row$record_id),id) ||
       !val(row$screening$decision)%in%c("retain","exclude","uncertain"))
      stop("Model result identity/decision mismatch for ",id)
    original<-val(row$screening$decision)
  } else {
    row<-list(record_id=id,screening=list())
    original<-""
  }
  human<-val(z$human_decision)
  if(nzchar(human)) {
    if(!human%in%c("retain","exclude")||!identical(human,val(z$decision)))
      stop("Human authority mismatch for ",id)
    row$screening$original_model_decision <- if(nzchar(original))original else NULL
    row$screening$decision <- human
    row$screening$decision_origin <- "human_screening_reconciled"
    row$screening$human_adjudication <- list(decision=human,
      source="verified_w04_human_screening")
    row$screening$requires_human_review <- FALSE
  } else if(!identical(original,val(z$decision))) {
    stop("Unexplained model decision override for ",id)
  }
  runs<-unlist(z$source_run_ids %||% list(),use.names=FALSE)
  if(length(runs)&& (anyNA(runs)||any(!grepl("^[0-9]+$",runs))))
    stop("Invalid contributing run IDs for ",id)
  row$screening$reconciliation <- list(
    source_run_ids=as.list(as.character(runs)),
    reconciliation_status="resolved",
    canonical_record_id=id)
  row
})
dir.create(output,recursive=TRUE,showWarnings=FALSE)
writej <- function(x,path)writeLines(vapply(x,jsonlite::toJSON,character(1),
  auto_unbox=TRUE,null="null",na="null",digits=NA),path,useBytes=TRUE)
writej(rows,file.path(output,"workflow04_consensus_layer.jsonl"))
file.create(file.path(output,"reused_workflow04_layer.jsonl"))
manifest <- list(schema="living-evidence-map-workflow04-incremental-prepare-v1",
 status="PASS",mode="reconciled_offline",canonical_records=length(ci),
 workflow03_excluded=sum(excluded),workflow03_eligible=length(eligible),
 reusable_records=0L,screen_queue_records=length(eligible),
 new_record_ids=0L,changed_screening_input=0L)
jsonlite::write_json(manifest,file.path(output,"prepare_manifest.json"),auto_unbox=TRUE,pretty=TRUE)
cat("PASS: offline reconciled W04 merge inputs:",length(eligible),"eligible records\n")
