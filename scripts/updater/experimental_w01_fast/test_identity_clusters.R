#!/usr/bin/env Rscript
suppressPackageStartupMessages(library(data.table))
root<-tempfile("identity-clusters-");dir.create(root)
script<-"scripts/updater/experimental_w01_fast/update_clusters_by_identity.R"
m<-data.table(source="a",source_record_id=c("A","B","C","D"))
prior<-m[1:3];prior[,cluster_id:=c("old-1","old-1","old-2")]
dec<-data.table(source_i="a",source_record_id_i="B",
 source_j="a",source_record_id_j="D",rescored_classification="duplicate")
pm<-file.path(root,"prior.csv");mp<-file.path(root,"current.csv");dp<-file.path(root,"dec.csv")
fwrite(prior,pm);fwrite(m,mp);fwrite(dec,dp)
run<-function(out,ok=TRUE){
 x<-suppressWarnings(system2(file.path(R.home("bin"),"Rscript"),
 c(script,"--prior-map",pm,"--metadata",mp,"--incremental-decisions",dp,
 "--output-dir",out),stdout=TRUE,stderr=TRUE))
 status<-attr(x,"status");if(is.null(status))status<-0L
 if((status==0L)!=ok)stop(paste("Unexpected exit",status,paste(x,collapse=" | ")))
}
a<-file.path(root,"first");run(a)
first<-fread(file.path(a,"identity_cluster_map.csv"))
stopifnot(identical(first$cluster_size,c(3L,3L,1L,3L)),
 identical(first$cluster_id[[1]],first$cluster_id[[4]]))
# Change every row position in current metadata and historical cluster map.
fwrite(m[c(4,2,1,3)],mp)
fwrite(prior[c(3,1,2)],pm)
b<-file.path(root,"permuted");run(b)
second<-fread(file.path(b,"identity_cluster_map.csv"))
setorder(first,source,source_record_id);setorder(second,source,source_record_id)
stopifnot(identical(first,second))
# No decision may be applied to an unknown source ID.
dec[1,source_record_id_j:="WRONG"];fwrite(dec,dp)
run(file.path(root,"unknown"),FALSE)
# A historical-to-historical edge cannot be introduced as an incremental decision.
dec[1,source_record_id_j:="A"];fwrite(dec,dp)
run(file.path(root,"old_pair"),FALSE)
cat("PASS: clustering invariant to row positions; invalid identity edges fail closed\n")

# Swapping the order and orientation of the decision must not change clusters.
dec<-data.table(source_i="a",source_record_id_i="D",
 source_j="a",source_record_id_j="B",rescored_classification="duplicate")
fwrite(dec,dp)
c<-file.path(root,"reversed_decision");run(c)
third<-fread(file.path(c,"identity_cluster_map.csv"))
setorder(third,source,source_record_id)
stopifnot(identical(first,third))
cat("PASS: undirected identity edges are orientation-invariant\\n")

# With no approved new edge, historical cluster identifiers must remain unchanged.
empty<-dec[0]
fwrite(empty,dp)
unchanged_out<-file.path(root,"unchanged");run(unchanged_out)
unchanged<-fread(file.path(unchanged_out,"identity_cluster_map.csv"))
historic<-merge(unchanged,prior,by=c("source","source_record_id"),
 suffixes=c("_actual","_original"))
stopifnot(all(historic$cluster_id_actual==historic$cluster_id_original))
cat("PASS: unchanged historical cluster IDs are preserved\\n")
