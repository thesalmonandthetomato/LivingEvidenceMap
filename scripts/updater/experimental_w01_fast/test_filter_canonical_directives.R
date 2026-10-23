#!/usr/bin/env Rscript
suppressPackageStartupMessages({library(data.table);library(jsonlite)})
root<-tempfile("fast-directives-");dir.create(root)
on.exit(unlink(root,recursive=TRUE,force=TRUE),add=TRUE)
at<-function(n)file.path(root,n)
fwrite(data.table(source="a",source_record_id="1",cluster_id="work-a",
 cluster_size=1L),at("affected.csv"))
line<-function(src,id,action)as.character(toJSON(
 list(source=src,source_record_id=id,action=action),auto_unbox=TRUE))
writeLines(c(line("a","1","set_title"),line("b","2","set_title")),at("repairs.jsonl"))
writeLines(c(line("a","1","strip_abstract"),line("b","2","strip_abstract")),at("strips.jsonl"))
run<-function(out)system2(file.path(R.home("bin"),"Rscript"),
 c("scripts/updater/experimental_w01_fast/filter_canonical_directives.R",
 "--affected-cluster-map",at("affected.csv"),
 "--strip-actions",at("strips.jsonl"),"--data-quality-repairs",at("repairs.jsonl"),
 "--output-dir",out),stdout=TRUE,stderr=TRUE)
z<-suppressWarnings(run(at("out")))
if(!is.null(attr(z,"status"))&&attr(z,"status")!=0L)stop(paste(z,collapse=" | "))
for(file in c("data_quality_repairs.jsonl","strip_actions.jsonl")){
 lines<-readLines(at(paste0("out/",file)))
 stopifnot(length(lines)==1L,fromJSON(lines[[1]])$source=="a")
}
cat("PASS: actual repair and abstract-strip directive filtering retains only affected immutable identity\n")
