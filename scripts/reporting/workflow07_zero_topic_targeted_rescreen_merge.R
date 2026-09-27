#!/usr/bin/env Rscript
suppressPackageStartupMessages({library(jsonlite);library(readr)})
args<-commandArgs(trailingOnly=TRUE)
arg<-function(flag,default=NULL){i<-match(flag,args);if(is.na(i))return(default);args[[i+1L]]}
root<-arg("--input-root");out<-arg("--output-dir","outputs/workflow07_zero_topic_rescreen_merged");expected<-as.integer(arg("--expected-shards","4"))
expected_records<-as.integer(arg("--expected-records","0"))
if(is.null(root))stop("Required: --input-root")
dir.create(out,recursive=TRUE,showWarnings=FALSE)
read_jsonl<-function(p){x<-readLines(p,warn=FALSE,encoding="UTF-8");x<-x[nzchar(trimws(x))];lapply(x,fromJSON,simplifyVector=FALSE)}
write_jsonl<-function(x,p){con<-file(p,"wt",encoding="UTF-8");on.exit(close(con));for(z in x)writeLines(toJSON(z,auto_unbox=TRUE,null="null",na="null"),con)}
scalar<-function(x){if(is.null(x)||!length(x))"" else as.character(x[[1L]])}
files<-list.files(root,pattern="final_rescreen\\.jsonl$",recursive=TRUE,full.names=TRUE)
if(length(files)!=expected)stop("Expected ",expected," shard outputs, found ",length(files))
rows<-unlist(lapply(files,read_jsonl),recursive=FALSE)
ids<-vapply(rows,function(x)scalar(x$record_id),character(1))
if(expected_records>0L && length(rows)!=expected_records)stop("Expected ",expected_records," merged records, found ",length(rows))
if(anyDuplicated(ids)||any(!nzchar(ids)))stop("Merged identity invariant failed")
ord<-order(ids);rows<-rows[ord];ids<-ids[ord]
write_jsonl(rows,file.path(out,"workflow07_zero_topic_targeted_rescreen.jsonl"))
dec<-vapply(rows,function(x)scalar(x$decision),character(1))
review<-rows[dec %in% c("exclude","uncertain")]
write_jsonl(review,file.path(out,"workflow07_zero_topic_human_review_candidates.jsonl"))
summary<-list(
 schema="living-evidence-map-workflow07-zero-topic-targeted-rescreen-merged-v1",
 records=length(rows),
 include=sum(dec=="include"),
 exclude=sum(dec=="exclude"),
 uncertain=sum(dec=="uncertain"),
 human_review_candidates=length(review),
 decision_policy="include consensus resolves zero-topic QC; exclude or uncertain proceeds to Workflow 08 human adjudication"
)
write_json(summary,file.path(out,"summary.json"),pretty=TRUE,auto_unbox=TRUE)
writeLines("PASS",file.path(out,"PASS.ok"))
cat(toJSON(summary,pretty=TRUE,auto_unbox=TRUE),"\n")
