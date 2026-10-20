#!/usr/bin/env Rscript
suppressPackageStartupMessages(library(jsonlite))
root<-tempfile("recombine-");dir.create(root)
rec<-function(id,v)toJSON(list(schema_version="living-evidence-map-canonical-v1",
 identity=list(record_id=id,record_id_type="deduplication_cluster_id"),
 canonical=list(title=v)),auto_unbox=TRUE)
prior<-file.path(root,"prior.jsonl");changed<-file.path(root,"changed.jsonl")
affected<-file.path(root,"affected.csv")
writeLines(c(rec("old","old title"),rec("stable","unchanged original bytes")),prior)
writeLines(rec("new","new title"),changed)
writeLines(c("stage,cluster_id","prior,old","successor,new"),affected)
script<-"scripts/updater/experimental_w01_fast/recombine_canonical_jsonl.R"
run<-function(out,ok=TRUE){
 log<-suppressWarnings(system2(file.path(R.home("bin"),"Rscript"),
 c(script,"--prior",prior,"--changed",changed,"--affected-works",affected,
 "--output-dir",out),stdout=TRUE,stderr=TRUE))
 status<-attr(log,"status");if(is.null(status))status<-0L
 if((status==0L)!=ok)stop(paste(status,paste(log,collapse=" | ")))
}
out<-file.path(root,"result");run(out)
lines<-readLines(file.path(out,"canonical.jsonl"))
stopifnot(length(lines)==2L,rec("stable","unchanged original bytes")%in%lines,
 rec("new","new title")%in%lines)
# Zero-change batch must preserve all historical JSONL records verbatim.
writeLines(character(),changed)
writeLines("stage,cluster_id",affected)
zero<-file.path(root,"zero");run(zero)
stopifnot(setequal(readLines(prior),readLines(file.path(zero,"canonical.jsonl"))))
# Fail closed on unauthorized additional regenerated work.
writeLines(rec("not-affected","bad"),changed)
run(file.path(root,"invalid"),FALSE)
cat("PASS: unchanged canonical bytes retained, affected successors inserted, invalids rejected\n")
