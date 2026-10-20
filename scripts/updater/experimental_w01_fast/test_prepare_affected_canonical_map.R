#!/usr/bin/env Rscript
suppressPackageStartupMessages(library(data.table))
root<-tempfile("canonical-scope-");dir.create(root)
script<-"scripts/updater/experimental_w01_fast/prepare_affected_canonical_map.R"
m<-data.table(source="a",source_record_id=c("A","B","C","D"),
 cluster_id=c("changed","changed","unchanged","changed"),cluster_size=c(3L,3L,1L,3L))
affected<-data.table(stage=c("prior","successor"),cluster_id=c("old","changed"))
mp<-file.path(root,"map.csv");ap<-file.path(root,"affected.csv")
fwrite(m,mp);fwrite(affected,ap)
run<-function(dest,ok=TRUE){
 log<-suppressWarnings(system2(file.path(R.home("bin"),"Rscript"),
 c(script,"--successor-map",mp,"--affected-works",ap,"--output-dir",dest),
 stdout=TRUE,stderr=TRUE))
 status<-attr(log,"status");if(is.null(status))status<-0L
 if((status==0L)!=ok)stop(paste(status,paste(log,collapse=" | ")))
}
one<-file.path(root,"one");run(one)
first<-fread(file.path(one,"affected_cluster_map.csv"))
scope<-jsonlite::fromJSON(file.path(one,"scope_manifest.json"))
stopifnot(identical(scope$compatible_with_unmodified_production_builder,FALSE),
          nrow(first)==3L,!any(first$source_record_id=="C"),
 all(first$cluster_id=="changed"))
fwrite(m[c(4,2,3,1)],mp)
two<-file.path(root,"two");run(two)
stopifnot(isTRUE(all.equal(as.data.frame(first),as.data.frame(
 fread(file.path(two,"affected_cluster_map.csv"))),check.attributes=FALSE)))
affected[stage=="successor",cluster_id:="missing"];fwrite(affected,ap)
run(file.path(root,"missing"),FALSE)
cat("PASS: affected canonical scope is identity-based and excludes untouched works\n")
