#!/usr/bin/env Rscript
suppressPackageStartupMessages({library(jsonlite);library(digest)})
root<-tempfile("state-");dir.create(root)
one<-file.path(root,"clusters.csv");two<-file.path(root,"decisions.csv")
writeLines(c("cluster_id,source","stable,a"),one);writeLines(c("pair,decision","a|b,match"),two)
script<-"scripts/updater/experimental_w01_fast/create_state_snapshot.R"
run<-function(out,ok=TRUE){
 z<-suppressWarnings(system2(file.path(R.home("bin"),"Rscript"),
 c(script,"--batch-id","batch-2026-10","--artifact",paste0("clusters=",one),
 "--artifact",paste0("decisions=",two),"--output-dir",out),stdout=TRUE,stderr=TRUE))
 code<-attr(z,"status");if(is.null(code))code<-0L
 if((code==0L)!=ok)stop(paste(code,paste(z,collapse=" | ")))
}
out<-file.path(root,"first");run(out)
manifest<-fromJSON(file.path(out,"manifest.json"),simplifyVector=FALSE)
stopifnot(identical(manifest$schema,"experimental-w01-fast-state-v1"),
 length(manifest$objects)==2L)
for(name in names(manifest$objects)){
 obj<-manifest$objects[[name]]
 stopifnot(identical(digest(file=file.path(out,obj$object),algo="sha256"),obj$sha256))
}
run(out,FALSE)
writeLines("changed",one)
stopifnot(identical(readLines(file.path(out,manifest$objects$clusters$object)),
 "cluster_id,source\nstable,a")==FALSE)
stopifnot(identical(digest(file=file.path(out,manifest$objects$clusters$object),algo="sha256"),
 manifest$objects$clusters$sha256))

verify<-function(ok=TRUE){
 z<-suppressWarnings(system2(file.path(R.home("bin"),"Rscript"),
 c("scripts/updater/experimental_w01_fast/verify_state_snapshot.R",
 "--snapshot-dir",out),stdout=TRUE,stderr=TRUE))
 status<-attr(z,"status");if(is.null(status))status<-0L
 if((status==0L)!=ok)stop(paste("Unexpected snapshot verification status",status))
}
verify()
object_path<-file.path(out,manifest$objects$clusters$object)
original<-readLines(object_path)
writeLines("corrupted",object_path)
verify(FALSE)
writeLines(original,object_path)
verify()
unlink(file.path(out,manifest$objects$decisions$object))
verify(FALSE)
cat("PASS: immutable snapshots, independent verification, corruption detection\\n")
