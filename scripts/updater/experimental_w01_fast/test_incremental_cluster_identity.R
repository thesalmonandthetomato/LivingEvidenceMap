#!/usr/bin/env Rscript
# Test W01-Fast cluster identity and safety boundaries using only small local fixtures.
suppressPackageStartupMessages({library(data.table);library(jsonlite);library(digest)})
root<-tempfile("w01-fast-identity-");dir.create(root)
script<-"scripts/updater/experimental_w01_fast/update_clusters.R"
meta<-data.table(idx=1:4,source=c("a","b","c","d"),source_record_id=c("A","B","C","D"))
group_id<-function(keys)paste0("work-",substr(digest(paste(sort(keys),collapse="|"),
  algo="sha256",serialize=FALSE),1,16))
prior<-meta[1:3,.(idx,source,source_record_id)]
prior[,cluster_id:=c(group_id(c("a:A","b:B")),group_id(c("a:A","b:B")),group_id("c:C"))]
prior[,cluster_size:=c(2L,2L,1L)]
dec<-data.table(record_i=2L,record_j=4L,rescored_classification="duplicate")
pmeta<-file.path(root,"metadata.csv");pprior<-file.path(root,"prior.csv")
pdec<-file.path(root,"decisions.csv");out<-file.path(root,"out")
fwrite(meta,pmeta);fwrite(prior,pprior);fwrite(dec,pdec)
run<-function(expect_success){
  result<-suppressWarnings(system2(file.path(R.home("bin"),"Rscript"),
    c(script,"--prior-map",pprior,"--metadata",pmeta,
      "--incremental-decisions",pdec,"--output-dir",out),
    stdout=TRUE,stderr=TRUE))
  status<-attr(result,"status");if(is.null(status))status<-0L
  if((status==0L)!=expect_success)
    stop(sprintf("Identity validation returned %s, expected success=%s: %s",
      status,expect_success,paste(result,collapse=" | ")))
}
run(TRUE)
result<-fread(file.path(out,"manifestation_cluster_map.csv"))
stopifnot(nrow(result)==4L,
  identical(result$cluster_size,c(3L,3L,1L,3L)),
  all(result$cluster_id[c(1L,2L,4L)]==group_id(c("a:A","b:B","d:D"))),
  identical(result$cluster_id[[3L]],group_id("c:C")))
# Historical manifestation identities must never be silently attached to new indices.
bad<-copy(meta);bad[1L,source_record_id:="WRONG"];fwrite(bad,pmeta);run(FALSE)
fwrite(meta,pmeta)
# Old-old decisions are forbidden; historical adjudications are immutable.
bad_dec<-data.table(record_i=1L,record_j=2L,rescored_classification="duplicate")
fwrite(bad_dec,pdec);run(FALSE)
# Repeated incremental edges must not be double-applied.
fwrite(rbind(dec,dec),pdec);run(FALSE)
cat("PASS: incremental merge and historical identity/decision rejection\n")
