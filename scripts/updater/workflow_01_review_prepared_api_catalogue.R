#!/usr/bin/env Rscript
# Read-only discovery of W01-ready JSONL handoffs restored from a review's W00 archive.
# Do not silently accept raw API payloads as converted bibliographic records.
suppressPackageStartupMessages({library(jsonlite);library(digest)})
args<-commandArgs(trailingOnly=TRUE)
get<-function(k){i<-match(k,args);if(is.na(i)||i==length(args))stop("Missing ",k,call.=FALSE);args[[i+1L]]}
pointer<-get("--w00-pointer")
root<-get("--restored-root")
output<-get("--output")
x<-fromJSON(pointer,simplifyVector=FALSE)
if(!identical(x$status,"published")||!identical(x$visibility,"restricted")||!nzchar(as.character(x$review_id)))
  stop("Review-specific W00 pointer required",call.=FALSE)
sources<-as.character(unlist(x$sources,use.names=FALSE))
if(!length(sources)||anyDuplicated(sources))stop("Invalid W00 source listing",call.=FALSE)
z<-list()
for(src in sources){
  if(!grepl("^[a-z0-9][a-z0-9_-]*$",src)) stop("Invalid W00 source",call.=FALSE)
  dir<-file.path(root,src)
  if(!dir.exists(dir))stop("Missing restored API source: ",src,call.=FALSE)
  candidates<-c(file.path(dir,"records.jsonl"),file.path(dir,"handoff","records.jsonl"),
    file.path(dir,"source_child","records.jsonl"))
  present<-candidates[file.exists(candidates)]
  if(length(present)!=1L)
    stop("W00 source ",src," has no unique prepared records.jsonl; existing API adapter must run first",call.=FALSE)
  lines<-readLines(present,warn=FALSE,encoding="UTF-8")
  lines<-lines[nzchar(trimws(lines))]
  ids<-character()
  for(line in lines){
    rec<-fromJSON(line,simplifyVector=FALSE)
    if(is.null(rec$sidecar_identity$sidecar_record_id) || is.null(rec$mapped_fields))
      stop("W00 ",src," has non-sidecar JSONL; existing W01 adapter must run first",call.=FALSE)
    ids<-c(ids,as.character(rec$sidecar_identity$sidecar_record_id))
  }
  if(anyDuplicated(ids))stop("Repeated sidecar identities in source ",src,call.=FALSE)
  z[[src]]<-list(kind="workflow00_state",source=src,prepared_path=present[[1L]],
    expected_records=length(lines),sha256=digest(file=present[[1L]],algo="sha256",serialize=FALSE))
}
dir.create(dirname(output),recursive=TRUE,showWarnings=FALSE)
write_json(list(schema="living-evidence-map-workflow01-source-catalogue-v1",
  review_id=x$review_id,sources=z),output,auto_unbox=TRUE,pretty=TRUE,null="null")
cat(sprintf("PASS: %d review-specific W00 sidecar sources\\n",length(z)))
