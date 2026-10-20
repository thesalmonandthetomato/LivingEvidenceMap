#!/usr/bin/env Rscript
suppressPackageStartupMessages({library(data.table);library(jsonlite)})
root<-tempfile("canonical-filter-");dir.create(root)
script<-"scripts/updater/experimental_w01_fast/filter_canonical_source_inputs.R"
source_path<-file.path(root,"lens.jsonl")
record<-function(id)toJSON(list(identity=list(lens_id=id),lens=list(raw_payload=list(title=id))),auto_unbox=TRUE)
writeLines(c(record("A"),record("B"),record("C")),source_path)
manifest<-file.path(root,"manifest.json")
writeLines(toJSON(list(schema="living-evidence-map-workflow01-source-inputs-v1",
 sources=list(lens=list(source_path))),auto_unbox=TRUE),manifest)
m<-data.table(source="lens",source_record_id=c("C","A"),cluster_id="new",
 cluster_size=2L)
map<-file.path(root,"map.csv");fwrite(m,map)
run<-function(dest,ok=TRUE){
 z<-suppressWarnings(system2(file.path(R.home("bin"),"Rscript"),
 c(script,"--affected-cluster-map",map,"--input-manifest",manifest,
 "--output-dir",dest),stdout=TRUE,stderr=TRUE))
 status<-attr(z,"status");if(is.null(status))status<-0L
 if((status==0L)!=ok)stop(paste(status,paste(z,collapse=" | ")))
}
dest<-file.path(root,"filtered");run(dest)
lines<-readLines(file.path(dest,"lens.jsonl"))
stopifnot(length(lines)==2L,
 identical(vapply(lines,function(s)fromJSON(s)$identity$lens_id,character(1)),
 c("A","C")))
# Selection must depend on immutable identity, not map row position.
fwrite(m[2:1],map);second<-file.path(root,"permuted");run(second)
stopifnot(identical(lines,readLines(file.path(second,"lens.jsonl"))))
# Fail if the requested record is absent.
m[1,source_record_id:="MISSING"];fwrite(m,map)
run(file.path(root,"missing"),FALSE)
# Disallow legacy composite-key ambiguity.
m[1,source_record_id:="A::B"];fwrite(m,map)
run(file.path(root,"collision"),FALSE)
cat("PASS: stable-identity JSONL filter, row permutation and fail-closed omissions\n")
