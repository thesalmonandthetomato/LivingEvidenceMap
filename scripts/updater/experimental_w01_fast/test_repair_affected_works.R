#!/usr/bin/env Rscript
suppressPackageStartupMessages({library(data.table);library(jsonlite)})
root<-tempfile("repair-works-");dir.create(root)
on.exit(unlink(root,recursive=TRUE,force=TRUE),add=TRUE)
at<-function(x)file.path(root,x)
z<-data.table(source=c("a","b"),source_record_id=c("1","2"),
 cluster_id=c("work-a","work-b"),cluster_size=1L)
fwrite(z,at("prior.csv"));fwrite(z,at("next.csv"))
writeLines(toJSON(list(review_case_id="fixture",source="a",source_record_id="1",
action="set_title",value="Corrected title"),auto_unbox=TRUE),at("repairs.jsonl"))
script<-"scripts/updater/experimental_w01_fast/identify_affected_works.R"
call<-function(repairs,out){
 a<-suppressWarnings(system2(file.path(R.home("bin"),"Rscript"),
 c(script,"--prior-map",at("prior.csv"),"--next-map",at("next.csv"),
 "--repairs",repairs,"--output-dir",out),stdout=TRUE,stderr=TRUE))
 if(!is.null(attr(a,"status"))&&attr(a,"status")!=0L)
  stop(paste(a,collapse=" | "))
}
call(at("repairs.jsonl"),at("affected"))
a<-fread(at("affected/affected_works.csv"))
stopifnot(nrow(a)==1L,a$stage=="successor",a$cluster_id=="work-a")
manifest<-fromJSON(at("affected/manifest.json"))
stopifnot(manifest$repair_affected_successor_works==1L)
writeLines(toJSON(list(source="x",source_record_id="missing",action="set_title"),auto_unbox=TRUE),at("invalid.jsonl"))
x<-suppressWarnings(system2(file.path(R.home("bin"),"Rscript"),
 c(script,"--prior-map",at("prior.csv"),"--next-map",at("next.csv"),
 "--repairs",at("invalid.jsonl"),"--output-dir",at("invalid")),stdout=TRUE,stderr=TRUE))
stopifnot(!is.null(attr(x,"status")),attr(x,"status")!=0L)
cat("PASS: repair-only canonical work included; unknown repair identity rejected\n")
