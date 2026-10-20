#!/usr/bin/env Rscript
suppressPackageStartupMessages({library(data.table);library(jsonlite)})
root<-tempfile("canonical-directives-");dir.create(root)
map<-file.path(root,"affected.csv")
m<-data.table(source="lens",source_record_id=c("A","B"),cluster_id="work-1",cluster_size=2L)
fwrite(m,map)
strips<-file.path(root,"strips.jsonl");repairs<-file.path(root,"repairs.jsonl")
make<-function(src,id,extras=list())toJSON(c(list(source=src,source_record_id=id),extras),auto_unbox=TRUE)
writeLines(c(make("lens","A"),make("lens","C")),strips)
writeLines(c(make("lens","C",list(action="set_title")),
 make("lens","B",list(action="set_abstract"))),repairs)
script<-"scripts/updater/experimental_w01_fast/filter_canonical_directives.R"
run<-function(dest,ok=TRUE){
 log<-suppressWarnings(system2(file.path(R.home("bin"),"Rscript"),
 c(script,"--affected-cluster-map",map,"--strip-actions",strips,
 "--data-quality-repairs",repairs,"--output-dir",dest),
 stdout=TRUE,stderr=TRUE))
 code<-attr(log,"status");if(is.null(code))code<-0L
 if((code==0L)!=ok)stop(paste(code,paste(log,collapse=" | ")))
}
first<-file.path(root,"first");run(first)
s<-readLines(file.path(first,"strip_actions.jsonl"))
r<-readLines(file.path(first,"data_quality_repairs.jsonl"))
stopifnot(length(s)==1L,length(r)==1L,
 fromJSON(s[[1L]])$source_record_id=="A",
 fromJSON(r[[1L]])$source_record_id=="B")
fwrite(m[2:1],map)
second<-file.path(root,"second");run(second)
stopifnot(identical(s,readLines(file.path(second,"strip_actions.jsonl"))),
 identical(r,readLines(file.path(second,"data_quality_repairs.jsonl"))))
writeLines(make("lens",""),strips)
run(file.path(root,"invalid"),FALSE)
cat("PASS: canonical directives are scoped by immutable identity, invariant to ordering\n")
