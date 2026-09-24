#!/usr/bin/env Rscript
suppressPackageStartupMessages(library(jsonlite))
args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag,default=NULL){i<-match(flag,args);if(is.na(i))return(default);if(i==length(args))stop(paste("Missing",flag));args[[i+1L]]}
source_path<-arg("--source"); original_path<-arg("--original-decisions"); targeted_path<-arg("--targeted-decisions"); out_path<-arg("--output")
if(any(vapply(list(source_path,original_path,targeted_path,out_path),is.null,logical(1)))) stop("Required args missing")
readj<-function(p){x<-readLines(p,warn=FALSE);x<-x[nzchar(trimws(x))];lapply(x,fromJSON,simplifyVector=FALSE)}
source<-readj(source_path); d<-c(readj(original_path),readj(targeted_path))
labels<-setNames(vapply(d,function(z)as.character(z$decision),character(1)),vapply(d,function(z)as.character(z$review_case_id),character(1)))
drop<-c("workflow","requested_model","resolved_model","response_id","api_usage","model_decision","model_confidence","model_rationale","technical_error","auto_threshold","promotion","promotion_reason","adjudicated_at_utc","abstract_consistent_with_record_i","abstract_consistent_with_record_j")
sel<-Filter(function(z)!is.null(labels[[as.character(z$review_case_id)]]) &&
  identical(z$deterministic_evidence$classifier_rule,"exact_abstract_insufficient_metadata") &&
  labels[[as.character(z$review_case_id)]] %in% c("duplicate","not_duplicate"),source)
if(length(sel)!=34L) stop(sprintf("Expected 34 labelled exact-abstract cases, found %d",length(sel)))
con<-file(out_path,"wt",encoding="UTF-8");on.exit(close(con),add=TRUE)
for(z in sel){z$human_validation_label<-labels[[as.character(z$review_case_id)]];z<-z[setdiff(names(z),drop)];writeLines(toJSON(z,auto_unbox=TRUE,null="null",na="null"),con)}
cat("PASS: built 34-case exact-abstract guard validation set\n")
