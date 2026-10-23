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
stopifnot(nrow(a)==2L,
 setequal(a$stage,c("prior","successor")),all(a$cluster_id=="work-a"))
# Actually recombine a corrected work; the prior instance must be retired.
canonical<-function(id,title)list(
 schema_version="living-evidence-map-canonical-v1",
 identity=list(record_id=id,record_id_type="deduplication_cluster_id"),
 canonical=list(title=title),
 manifestations=list(list(source="a",source_record_id="1")))
writeLines(vapply(list(canonical("work-a","Original"),canonical("work-b","Untouched")),
 function(x)toJSON(x,auto_unbox=TRUE,null="null"),character(1)),at("prior_records.jsonl"))
writeLines(toJSON(canonical("work-a","Corrected"),auto_unbox=TRUE,null="null"),
 at("changed_records.jsonl"))
combine<-suppressWarnings(system2(file.path(R.home("bin"),"Rscript"),
 c("scripts/updater/experimental_w01_fast/recombine_canonical_jsonl.R",
 "--prior",at("prior_records.jsonl"),"--changed",at("changed_records.jsonl"),
 "--affected-works",at("affected/affected_works.csv"),
 "--output-dir",at("recombined")),stdout=TRUE,stderr=TRUE))
if(!is.null(attr(combine,"status"))&&attr(combine,"status")!=0L)
 stop(paste(combine,collapse=" | "))
records<-lapply(readLines(at("recombined/canonical.jsonl")),fromJSON)
titles<-setNames(vapply(records,function(x)x$canonical$title,character(1)),
 vapply(records,function(x)x$identity$record_id,character(1)))
stopifnot(length(titles)==2L,titles[["work-a"]]=="Corrected",
 titles[["work-b"]]=="Untouched")
manifest<-fromJSON(at("affected/manifest.json"))
stopifnot(manifest$repair_affected_successor_works==1L,
 manifest$repair_affected_prior_works==1L)
writeLines(toJSON(list(source="x",source_record_id="missing",action="set_title"),auto_unbox=TRUE),at("invalid.jsonl"))
x<-suppressWarnings(system2(file.path(R.home("bin"),"Rscript"),
 c(script,"--prior-map",at("prior.csv"),"--next-map",at("next.csv"),
 "--repairs",at("invalid.jsonl"),"--output-dir",at("invalid")),stdout=TRUE,stderr=TRUE))
stopifnot(!is.null(attr(x,"status")),attr(x,"status")!=0L)
cat("PASS: repair-only canonical work included; unknown repair identity rejected\n")
