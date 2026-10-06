#!/usr/bin/env Rscript
suppressPackageStartupMessages(library(jsonlite))

args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag,default=NULL){i<-match(flag,args);if(is.na(i))return(default);if(i==length(args))stop(sprintf("Missing value after %s",flag),call.=FALSE);args[[i+1L]]}
canonical_path <- arg("--canonical")
w03_path <- arg("--w03")
w04_layer_path <- arg("--w04-layer","")
usage_dir <- arg("--usage-dir","")
out_path <- arg("--output","outputs/w04_abstract_partial_match_audit.json")
ids_path <- arg("--affected-ids","outputs/w04_abstract_partial_match_affected_ids.txt")
if(is.null(canonical_path)||is.null(w03_path)) stop("Required: --canonical --w03",call.=FALSE)

`%||%` <- function(x,y) if(is.null(x)) y else x
scalar <- function(x){if(is.null(x)||!length(x))return("");z<-as.character(x[[1L]]);if(is.na(z))"" else trimws(z)}
textify <- function(x){
  if(is.null(x)) return("")
  if(is.character(x)) return(paste(x[nzchar(x)],collapse="; "))
  if(is.atomic(x)) return(paste(as.character(x),collapse="; "))
  if(is.list(x)) return(paste(Filter(nzchar,vapply(x,textify,character(1))),collapse="; "))
  as.character(x)
}
read_jsonl <- function(path){
  x<-readLines(path,warn=FALSE,encoding="UTF-8");x<-x[nzchar(trimws(x))]
  lapply(x,fromJSON,simplifyVector=FALSE)
}
rid <- function(r) scalar((r$identity %||% list())$record_id)
w03_excluded <- function(x) isTRUE((x$publication_status %||% list())$exclude_from_workflow04 %||% x$exclude_from_workflow04 %||% FALSE)
exact_value <- function(x,name) if(is.list(x) && name %in% names(x)) x[[name,exact=TRUE]] else NULL
missing_text <- function(x) !nzchar(trimws(textify(x)))

canonical <- read_jsonl(canonical_path)
w03 <- read_jsonl(w03_path)
cids <- vapply(canonical,rid,character(1))
wids <- vapply(w03,function(x)scalar(x$record_id),character(1))
if(any(!nzchar(cids))||anyDuplicated(cids)) stop("Canonical record_id invariant failed",call.=FALSE)
if(any(!nzchar(wids))||anyDuplicated(wids)||!setequal(cids,wids)) stop("W03 identity invariant failed",call.=FALSE)
wmap <- setNames(w03,wids)

is_affected <- function(r){
  c <- exact_value(r,"canonical") %||% list()
  if(!missing_text(exact_value(c,"abstract"))) return(FALSE)
  if(!is.null(exact_value(r,"abstract")) && !missing_text(exact_value(r,"abstract"))) return(FALSE)
  nms <- names(r) %||% character()
  partial <- nms[startsWith(nms,"abstract")]
  if(length(partial)!=1L || !identical(partial,"abstract_enrichment")) return(FALSE)
  nzchar(trimws(textify(exact_value(r,"abstract_enrichment"))))
}
affected_all <- cids[vapply(canonical,is_affected,logical(1))]
eligible <- cids[!vapply(cids,function(id)w03_excluded(wmap[[id]]),logical(1))]
affected <- sort(intersect(affected_all,eligible))

layer <- if(nzchar(w04_layer_path) && file.exists(w04_layer_path)) read_jsonl(w04_layer_path) else list()
layer_map <- if(length(layer)) setNames(layer,vapply(layer,function(x)scalar(x$record_id),character(1))) else list()
affected_layer <- Filter(Negate(is.null),unname(layer_map[affected]))
decision_counts <- if(length(affected_layer)){
  table(vapply(affected_layer,function(x)scalar((x$screening %||% list())$decision),character(1)))
} else integer()
origin_counts <- if(length(affected_layer)){
  table(vapply(affected_layer,function(x)scalar((x$screening %||% list())$decision_origin),character(1)))
} else integer()

pass_files <- character()
if(nzchar(usage_dir) && dir.exists(usage_dir)){
  pass_files <- list.files(usage_dir,pattern="^pass[123].*\\.jsonl$",recursive=TRUE,full.names=TRUE)
}
calls <- list()
if(length(pass_files)){
  for(p in pass_files){
    xs <- tryCatch(read_jsonl(p),error=function(e)list())
    if(length(xs)) calls <- c(calls,xs)
  }
}
if(length(calls)){
  keys <- vapply(seq_along(calls),function(i){
    z<-calls[[i]]
    id<-scalar(z$response_id)
    if(nzchar(id)) id else paste(scalar(z$record_id),scalar(z$pass),i,sep="|")
  },character(1))
  calls <- calls[!duplicated(keys)]
}
screened_ids <- if(length(calls)) unique(vapply(calls,function(x)scalar(x$record_id),character(1))) else character()
affected_screened_this_run <- intersect(affected,screened_ids)

usage_num <- function(u,name){
  z<-u[[name]]
  if(is.null(z)||!length(z)) return(0)
  v<-suppressWarnings(as.numeric(z[[1L]])); if(is.na(v))0 else v
}
usage <- list(calls=length(calls),input_tokens=0,cached_input_tokens=0,output_tokens=0)
if(length(calls)){
  for(z in calls){
    u<-z$usage %||% list()
    usage$input_tokens <- usage$input_tokens + usage_num(u,"input_tokens")
    det<-u$input_tokens_details %||% list()
    usage$cached_input_tokens <- usage$cached_input_tokens + usage_num(det,"cached_tokens")
    usage$output_tokens <- usage$output_tokens + usage_num(u,"output_tokens")
  }
}
usage$avg_input_tokens_per_call <- if(usage$calls) usage$input_tokens/usage$calls else NULL
usage$avg_cached_input_tokens_per_call <- if(usage$calls) usage$cached_input_tokens/usage$calls else NULL
usage$avg_output_tokens_per_call <- if(usage$calls) usage$output_tokens/usage$calls else NULL
usage$affected_calls_if_two_passes <- 2L*length(affected)
usage$affected_calls_if_three_passes <- 3L*length(affected)

sample_rows <- lapply(head(affected,20L),function(id){
  r<-canonical[[match(id,cids)]]
  list(
    record_id=id,
    title=textify(exact_value(exact_value(r,"canonical") %||% list(),"title")),
    abstract_enrichment=textify(exact_value(r,"abstract_enrichment")),
    current_w04_decision=if(id %in% names(layer_map)) scalar((layer_map[[id]]$screening %||% list())$decision) else "",
    current_w04_origin=if(id %in% names(layer_map)) scalar((layer_map[[id]]$screening %||% list())$decision_origin) else ""
  )
})

report <- list(
  schema="living-evidence-map-w04-abstract-partial-match-audit-v1",
  status="PASS",
  canonical_records=length(canonical),
  workflow04_eligible_records=length(eligible),
  affected_all_canonical=length(affected_all),
  affected_workflow04_eligible=length(affected),
  affected_present_in_w04_layer=length(affected_layer),
  affected_screened_in_current_run=length(affected_screened_this_run),
  affected_decision_counts=as.list(decision_counts),
  affected_decision_origin_counts=as.list(origin_counts),
  usage=usage,
  sample=sample_rows
)
dir.create(dirname(out_path),recursive=TRUE,showWarnings=FALSE)
writeLines(toJSON(report,auto_unbox=TRUE,pretty=TRUE,null="null",na="null"),out_path,useBytes=TRUE)
dir.create(dirname(ids_path),recursive=TRUE,showWarnings=FALSE)
writeLines(affected,ids_path,useBytes=TRUE)
cat(toJSON(report,auto_unbox=TRUE,pretty=TRUE,null="null",na="null"),"\n")
