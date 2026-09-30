#!/usr/bin/env Rscript
suppressPackageStartupMessages({library(jsonlite);library(digest)})

args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag,default=NULL){i<-match(flag,args);if(is.na(i))return(default);if(i==length(args))stop(sprintf("Missing value after %s",flag),call.=FALSE);args[[i+1L]]}

canonical_path <- arg("--canonical")
w03_path <- arg("--workflow03-status")
prior_w04_path <- arg("--prior-workflow04","")
prior_canonical_path <- arg("--prior-canonical","")
output_dir <- arg("--output-dir","outputs/workflow04_prepare")

if(is.null(canonical_path)||is.null(w03_path)) stop("Required: --canonical --workflow03-status",call.=FALSE)
if(!file.exists(canonical_path)||!file.exists(w03_path)) stop("Current canonical/W03 input missing",call.=FALSE)
if(nzchar(prior_w04_path)&&!file.exists(prior_w04_path)) stop("Prior Workflow 04 layer not found",call.=FALSE)
if(nzchar(prior_canonical_path)&&!file.exists(prior_canonical_path)) stop("Prior canonical input not found",call.=FALSE)
dir.create(output_dir,recursive=TRUE,showWarnings=FALSE)

`%||%` <- function(x,y) if(is.null(x)) y else x
scalar <- function(x){if(is.null(x)||!length(x))return("");z<-as.character(x[[1L]]);if(is.na(z))"" else trimws(z)}
read_jsonl <- function(path){
  x<-readLines(path,warn=FALSE,encoding="UTF-8");x<-x[nzchar(trimws(x))]
  lapply(seq_along(x),function(i)tryCatch(fromJSON(x[[i]],simplifyVector=FALSE),error=function(e)stop(sprintf("Invalid JSONL %s line %d: %s",path,i,conditionMessage(e)),call.=FALSE)))
}
write_jsonl <- function(rows,path){
  con<-file(path,"wt",encoding="UTF-8");on.exit(close(con),add=TRUE)
  if(length(rows))for(x in rows)writeLines(toJSON(x,auto_unbox=TRUE,null="null",na="null",digits=NA),con,useBytes=TRUE)
}
textify <- function(x){
  if(is.null(x))return("")
  if(is.character(x))return(paste(x[nzchar(x)],collapse="; "))
  if(is.atomic(x))return(paste(as.character(x),collapse="; "))
  if(is.list(x))return(paste(Filter(nzchar,vapply(x,textify,character(1))),collapse="; "))
  as.character(x)
}
first_nonempty <- function(...){for(x in list(...)){z<-textify(x);if(nzchar(trimws(z)))return(trimws(z))};""}
record_id <- function(r) scalar((r$identity %||% list())$record_id)
w03_id <- function(r) scalar(r$record_id)
w03_excluded <- function(x) isTRUE((x$publication_status %||% list())$exclude_from_workflow04 %||% x$exclude_from_workflow04 %||% FALSE)

# This intentionally mirrors the stable metadata view used by the W04 screener.
# New additive canonical fields are preserved in the canonical JSONL but do not
# alter reuse unless they are explicitly part of the screening view.
screening_view <- function(r){
  c<-r$canonical %||% list()
  list(
    title=first_nonempty(c$title,r$title),
    abstract=first_nonempty(c$abstract,r$abstract),
    keywords=first_nonempty(c$keywords,r$keywords),
    journal_source_title=first_nonempty(c$source_title,c$journal,r$source_title,r$journal),
    affiliations=first_nonempty(c$affiliations,r$affiliations),
    funding=first_nonempty(c$funding,c$funders,r$funding,r$funders)
  )
}
fingerprint <- function(r){
  v<-screening_view(r)
  digest(toJSON(v,auto_unbox=TRUE,null="null",na="null",digits=NA),algo="sha256",serialize=FALSE)
}

canonical <- read_jsonl(canonical_path)
w03 <- read_jsonl(w03_path)
cids <- vapply(canonical,record_id,character(1))
wids <- vapply(w03,w03_id,character(1))
if(any(!nzchar(cids))||anyDuplicated(cids)) stop("Current canonical record_id invariant failed",call.=FALSE)
if(any(!nzchar(wids))||anyDuplicated(wids)||!setequal(cids,wids)) stop("Current Workflow 03 identity invariant failed",call.=FALSE)
w03map <- setNames(w03,wids)

eligible_ids <- cids[!vapply(cids,function(id)w03_excluded(w03map[[id]]),logical(1))]
eligible_ids <- sort(eligible_ids)
cmap <- setNames(canonical,cids)
current_fp <- setNames(vapply(eligible_ids,function(id)fingerprint(cmap[[id]]),character(1)),eligible_ids)

prior <- list(); prior_ids <- character(); prior_map <- list(); prior_fp <- character()
mode <- "first_run"
if(nzchar(prior_w04_path)){
  mode <- "update"
  prior <- read_jsonl(prior_w04_path)
  prior_ids <- vapply(prior,function(x)scalar(x$record_id),character(1))
  if(any(!nzchar(prior_ids))||anyDuplicated(prior_ids)) stop("Prior Workflow 04 record_id invariant failed",call.=FALSE)
  prior_map <- setNames(prior,prior_ids)

  prior_fp <- setNames(vapply(prior,function(x)scalar((x$screening %||% list())$screening_input_sha256),character(1)),prior_ids)
  missing_fp <- names(prior_fp)[!nzchar(prior_fp)]
  if(length(missing_fp)){
    if(!nzchar(prior_canonical_path)) stop(sprintf("Prior W04 layer lacks fingerprints for %d records; --prior-canonical is required for bootstrap",length(missing_fp)),call.=FALSE)
    pc <- read_jsonl(prior_canonical_path)
    pcids <- vapply(pc,record_id,character(1))
    if(any(!nzchar(pcids))||anyDuplicated(pcids)) stop("Prior canonical record_id invariant failed",call.=FALSE)
    pcmap <- setNames(pc,pcids)
    absent <- setdiff(missing_fp,pcids)
    if(length(absent)) stop(sprintf("Prior canonical lacks %d W04 records needed to bootstrap fingerprints",length(absent)),call.=FALSE)
    prior_fp[missing_fp] <- vapply(missing_fp,function(id)fingerprint(pcmap[[id]]),character(1))
  }
}

known <- intersect(eligible_ids,prior_ids)
new_ids <- setdiff(eligible_ids,prior_ids)
changed_ids <- known[current_fp[known] != prior_fp[known]]
reuse_ids <- setdiff(known,changed_ids)
queue_ids <- sort(c(new_ids,changed_ids))
reuse_ids <- sort(reuse_ids)

queue_canonical <- unname(cmap[queue_ids])
queue_w03 <- unname(w03map[queue_ids])

reuse_rows <- lapply(reuse_ids,function(id){
  z <- prior_map[[id]]
  if(is.null(z$screening)||!is.list(z$screening)) stop(sprintf("Prior W04 row lacks screening object: %s",id),call.=FALSE)
  d <- scalar(z$screening$decision)
  if(!d %in% c("retain","exclude")) stop(sprintf("Prior W04 reusable decision is not substantive for %s",id),call.=FALSE)
  z$screening$screening_input_sha256 <- unname(current_fp[[id]])
  z$screening$reuse <- list(
    reused=TRUE,
    basis="stable_record_id_and_unchanged_screening_input_sha256",
    prior_workflow04_record=TRUE
  )
  z
})

write_jsonl(queue_canonical,file.path(output_dir,"screen_queue_canonical.jsonl"))
write_jsonl(queue_w03,file.path(output_dir,"screen_queue_workflow03.jsonl"))
write_jsonl(reuse_rows,file.path(output_dir,"reused_workflow04_layer.jsonl"))
writeLines(queue_ids,file.path(output_dir,"screen_queue_record_ids.txt"),useBytes=TRUE)
writeLines(reuse_ids,file.path(output_dir,"reused_record_ids.txt"),useBytes=TRUE)

reason_rows <- data.frame(
  record_id=queue_ids,
  queue_reason=ifelse(queue_ids%in%new_ids,"new_record_id","changed_screening_input"),
  screening_input_sha256=unname(current_fp[queue_ids]),
  stringsAsFactors=FALSE
)
write.csv(reason_rows,file.path(output_dir,"screen_queue_manifest.csv"),row.names=FALSE,na="")

manifest <- list(
  schema="living-evidence-map-workflow04-incremental-prepare-v1",
  status="PASS",
  mode=mode,
  canonical_records=length(cids),
  workflow03_excluded=length(cids)-length(eligible_ids),
  workflow03_eligible=length(eligible_ids),
  prior_workflow04_records=length(prior_ids),
  reusable_records=length(reuse_ids),
  screen_queue_records=length(queue_ids),
  new_record_ids=length(new_ids),
  changed_screening_input=length(changed_ids),
  prior_records_not_currently_w03_eligible=length(setdiff(prior_ids,eligible_ids)),
  screening_fingerprint_fields=c("title","abstract","keywords","journal_source_title","affiliations","funding"),
  canonical_sha256=digest(file=canonical_path,algo="sha256",serialize=FALSE),
  workflow03_sha256=digest(file=w03_path,algo="sha256",serialize=FALSE),
  prior_workflow04_sha256=if(nzchar(prior_w04_path))digest(file=prior_w04_path,algo="sha256",serialize=FALSE)else NULL,
  generated_at_utc=format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ")
)
writeLines(toJSON(manifest,auto_unbox=TRUE,pretty=TRUE,null="null"),file.path(output_dir,"prepare_manifest.json"),useBytes=TRUE)
cat(sprintf("PASS: W04 %s preparation: eligible=%d reuse=%d screen=%d (new=%d changed=%d)\n",
            mode,length(eligible_ids),length(reuse_ids),length(queue_ids),length(new_ids),length(changed_ids)))
