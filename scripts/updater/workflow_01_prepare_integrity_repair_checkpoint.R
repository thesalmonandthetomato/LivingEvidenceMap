#!/usr/bin/env Rscript
suppressPackageStartupMessages({library(jsonlite);library(data.table);library(digest)})
args<-commandArgs(trailingOnly=TRUE)
arg<-function(flag,default=NULL){i<-match(flag,args);if(is.na(i))return(default);if(i==length(args))stop(sprintf("Missing value after %s",flag),call.=FALSE);args[[i+1L]]}
checkpoint_manifest<-arg("--checkpoint-manifest");source_manifest<-arg("--source-manifest");pre_map<-arg("--pre-map");output<-arg("--output")
if(any(vapply(list(checkpoint_manifest,source_manifest,pre_map,output),is.null,logical(1))))stop("Required arguments missing",call.=FALSE)

cm<-fromJSON(checkpoint_manifest,simplifyVector=FALSE)
sm<-fromJSON(source_manifest,simplifyVector=FALSE)
if(!identical(sm$schema,"living-evidence-map-workflow01-source-inputs-v1"))stop("Invalid original source-input manifest",call.=FALSE)
source_order<-names(sm$sources)
if(is.null(source_order)||!length(source_order)||anyDuplicated(source_order))stop("Original source-input manifest has invalid order",call.=FALSE)
counts<-cm$new_source_manifestations_by_source
if(is.null(counts)||!setequal(names(counts),source_order))stop("Checkpoint source namespaces differ from original source-input manifest",call.=FALSE)

m<-fread(pre_map,select=c("idx","source","source_record_id"),na.strings=c("","NA"))
setorder(m,idx)
if(!identical(as.integer(m$idx),seq_len(nrow(m))))stop("Original pre-adjudication index is not contiguous",call.=FALSE)
payload<-paste(paste(m$idx,m$source,m$source_record_id,sep="\t"),collapse="\n")
sha<-digest(payload,algo="sha256",serialize=FALSE)

cm$source_order<-unname(source_order)
cm$dedup_index_identity<-list(rows=nrow(m),sha256=sha,key="idx\\tsource\\tsource_record_id")
cm$repair_provenance<-list(
  reason="recover_original_pre_adjudication_index_identity_after_checkpoint_source_order_permutation",
  source_manifest_sha256=digest(file=source_manifest,algo="sha256",serialize=FALSE),
  pre_adjudication_map_sha256=digest(file=pre_map,algo="sha256",serialize=FALSE)
)
dir.create(dirname(output),recursive=TRUE,showWarnings=FALSE)
writeLines(toJSON(cm,auto_unbox=TRUE,pretty=TRUE,null="null"),output,useBytes=TRUE)
cat(sprintf("PASS: repaired checkpoint contract with %d manifestations; sha256=%s\n",nrow(m),sha))
