#!/usr/bin/env Rscript
# Evidence-backed current-run empty human repair ledger; NOT a replacement for
# human review when any unresolved decisions or current-run repairs exist.
suppressPackageStartupMessages({library(jsonlite);library(data.table);library(digest)})
a<-commandArgs(trailingOnly=TRUE)
arg<-function(k){i<-match(k,a);if(is.na(i)||i==length(a))stop("Missing ",k);a[[i+1L]]}
fast<-arg("--fast-root");prior<-arg("--prior-repairs");out<-arg("--output-dir")
if(dir.exists(out)||file.exists(out))stop("Cannot replace review certificate")
summary<-file.path(fast,"production_final","summary.json")
ledger<-file.path(fast,"production_final","final_pair_decisions.csv")
cumulative<-file.path(fast,"production_final","cumulative_data_quality_repairs.jsonl")
if(any(!file.exists(c(summary,ledger,cumulative,prior))))stop("Missing review/provenance evidence")
s<-fromJSON(summary)
fields<-c("human_final_decisions","manual_review_pairs","unresolved_pair_decisions","adjudicated_cases","llm_final_decisions")
if(any(vapply(fields,function(k)length(s[[k]])!=1L||is.na(s[[k]])||as.integer(s[[k]])!=0L,logical(1))))
 stop("Review not proven empty")
d<-fread(ledger,select=c("rescored_classification","review_route"))
if(anyNA(d)||any(d$review_route=="manual_review")||
 any(d$rescored_classification=="review"))
 stop("Manual adjudication remains or review decision missing")
hash<-function(x)digest(file=x,algo="sha256",serialize=FALSE)
if(!identical(hash(prior),hash(cumulative)))
 stop("Historical repairs changed; cannot certify zero current repairs")
dir.create(out,recursive=TRUE)
file.create(file.path(out,"data_quality_repairs.normalised.jsonl"))
write_json(list(schema="w01-fast-zero-current-review-certificate-v1",
 status="PASS_NO_CURRENT_REVIEW",review_summary_fields=as.list(s[fields]),
 previous_repair_sha256=hash(prior),current_cumulative_repair_sha256=hash(cumulative),
 cumulative_decision_sha256=hash(ledger),current_normalised_repairs=0L,
 publication_allowed=FALSE),
 file.path(out,"certificate.json"),auto_unbox=TRUE,pretty=TRUE)
cat("PASS: no unresolved review cases and unchanged previous repair ledger; certified zero current-run repairs\n")
