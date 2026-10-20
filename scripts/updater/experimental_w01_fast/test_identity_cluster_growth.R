#!/usr/bin/env Rscript
suppressPackageStartupMessages({library(data.table);library(jsonlite)})
root<-tempfile("cluster-growth-");dir.create(root)
meta<-data.table(source=c("lens","cab","proquest"),source_record_id=c("L1","C1","P1"))
prior<-meta[1:2];prior[,cluster_id:=c("historical-work-17","historical-work-18")]
dec<-data.table(source_i="lens",source_record_id_i="L1",source_j="proquest",
 source_record_id_j="P1",rescored_classification="duplicate")
write_inputs<-function(m,d){fwrite(m,file.path(root,"metadata.csv"));fwrite(d,file.path(root,"decisions.csv"))}
fwrite(prior,file.path(root,"prior.csv"))
runner<-file.path(R.home("bin"),"Rscript")
script<-"scripts/updater/experimental_w01_fast/update_clusters_by_identity.R"
run<-function(name,success=TRUE){
 o<-file.path(root,name)
 z<-suppressWarnings(system2(runner,c(script,"--prior-map",file.path(root,"prior.csv"),
 "--metadata",file.path(root,"metadata.csv"),"--incremental-decisions",file.path(root,"decisions.csv"),
 "--output-dir",o),stdout=TRUE,stderr=TRUE))
 code<-attr(z,"status");if(is.null(code))code<-0L
 if((code==0L)!=success)stop(paste("Unexpected result",code,paste(z,collapse="; ")))
 if(success)fread(file.path(o,"identity_cluster_map.csv")) else invisible(NULL)
}
write_inputs(meta,dec)
x<-run("original")
stopifnot(identical(x$cluster_id,c("historical-work-17","historical-work-18","historical-work-17")))
# Permuted rows and reversed decisions yield precisely identical keyed output.
m<-meta[c(3,1,2)];d<-copy(dec)
for(n in c("source","source_record_id")){
 a<-paste0(n,"_i");b<-paste0(n,"_j");t<-d[[a]];set(d,j=a,value=d[[b]]);set(d,j=b,value=t)
}
write_inputs(m,d);y<-run("permuted")
setorder(x,source,source_record_id);setorder(y,source,source_record_id)
stopifnot(identical(x$cluster_id,y$cluster_id),identical(x$cluster_size,y$cluster_size))
# Never implicitly merge distinct historical works.
d<-rbind(d,data.table(source_i="cab",source_record_id_i="C1",
 source_j="proquest",source_record_id_j="P1",rescored_classification="duplicate"))
write_inputs(m,d);run("unapproved-historic-merge",FALSE)
# No positional columns may act as decision identities.
write_inputs(m,data.table(record_i=1,record_j=3,rescored_classification="duplicate"))
run("positional-decision",FALSE)
cat("PASS: identity clustering preserves historical IDs, withstands permutation, rejects unsafe merges\n")
