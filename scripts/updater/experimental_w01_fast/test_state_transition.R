#!/usr/bin/env Rscript
suppressPackageStartupMessages({library(jsonlite);library(digest)})
root<-tempfile("state-transition-");dir.create(root)
artifact<-file.path(root,"clusters.csv");writeLines("a,b",artifact)
runner<-file.path(R.home("bin"),"Rscript")
run<-function(script,args,ok=TRUE){
 z<-suppressWarnings(system2(runner,c(script,args),stdout=TRUE,stderr=TRUE))
 status<-attr(z,"status");if(is.null(status))status<-0L
 if((status==0L)!=ok)stop(paste(status,paste(z,collapse=" | ")))
}
snapshot<-function(batch,dir)run("scripts/updater/experimental_w01_fast/create_state_snapshot.R",
 c("--batch-id",batch,"--artifact",paste0("clusters=",artifact),"--output-dir",dir))
first<-file.path(root,"first");second<-file.path(root,"second")
snapshot("2026-09",first);writeLines("a,b\nc,d",artifact);snapshot("2026-10",second)
script<-"scripts/updater/experimental_w01_fast/link_state_transition.R"
transition<-file.path(root,"transition.json")
run(script,c("--before",first,"--after",second,"--output",transition))
m<-fromJSON(transition,simplifyVector=FALSE)
stopifnot(identical(m$schema,"experimental-w01-fast-transition-v1"),
 setequal(unlist(m$changed_objects,use.names=FALSE),"clusters"),
 identical(m$previous_manifest_sha256,digest(file=file.path(first,"manifest.json"),algo="sha256")))
run(script,c("--before",first,"--after",second,"--output",transition),FALSE)
obj<-fromJSON(file.path(second,"manifest.json"))$objects$clusters$object
writeLines("corrupted",file.path(second,obj))
run(script,c("--before",first,"--after",second,"--output",file.path(root,"invalid.json")),FALSE)
cat("PASS: state transition verifies snapshots, identifies change and refuses corruption\n")
