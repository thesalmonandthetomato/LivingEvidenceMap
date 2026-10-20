#!/usr/bin/env Rscript
# Real-data October clustering replay against recovered W01 authoritative maps.
# This checks whether a set of stable-identity duplicate links derived from the
# verified reference can be reproduced by the independent W01-Fast cluster updater.
# It does NOT test independent candidate discovery or decision classification.
suppressPackageStartupMessages({library(data.table);library(jsonlite)})
root <- "reference"
old <- fread(file.path(root,"previous_state/workflow01_full_five_source/manifestation_cluster_map.csv"),colClasses="character")
final <- fread(file.path(root,"outputs/final/manifestation_cluster_map.csv"),colClasses="character")
key <- function(s,id)paste0(nchar(s,type="bytes"),":",s,nchar(id,type="bytes"),":",id)
old[,identity:=key(source,source_record_id)]
final[,identity:=key(source,source_record_id)]
stopifnot(!anyDuplicated(old$identity),!anyDuplicated(final$identity),all(old$identity%in%final$identity))
appended<-final[!identity%in%old$identity]
prior_clusters<-split(old$identity,old$cluster_id)
new_clusters<-split(appended$identity,appended$cluster_id)
# Build one reference duplicate edge per appended member, with stable endpoints.
rows<-list()
for(cid in names(new_clusters)){
 members<-new_clusters[[cid]]
 historical<-prior_clusters[[cid]]
 if(!is.null(historical) && length(historical)){
   anchor<-historical[[1L]]
   for(k in members)rows[[length(rows)+1L]]<-c(anchor,k)
 } else if(length(members)>1L) {
   for(k in members[-1L])rows[[length(rows)+1L]]<-c(members[[1L]],k)
 }
}
lookup<-final[,.(identity,source,source_record_id)]
setkey(lookup,identity)
dec<-data.table(source_i=character(),source_record_id_i=character(),source_j=character(),source_record_id_j=character(),rescored_classification=character())
for(pair in rows){
 a<-lookup[pair[[1L]]];b<-lookup[pair[[2L]]]
 dec<-rbind(dec,data.table(source_i=a$source,source_record_id_i=a$source_record_id,
 source_j=b$source,source_record_id_j=b$source_record_id,rescored_classification="duplicate"))
}
dir.create("october_identity_parity",showWarnings=FALSE)
fwrite(final[,.(source,source_record_id)],"october_identity_parity/metadata.csv")
fwrite(dec,"october_identity_parity/decisions.csv")
runner<-file.path(R.home("bin"),"Rscript")
z<-suppressWarnings(system2(runner,c("scripts/updater/experimental_w01_fast/update_clusters_by_identity.R",
 "--prior-map",file.path(root,"previous_state/workflow01_full_five_source/manifestation_cluster_map.csv"),
 "--metadata","october_identity_parity/metadata.csv",
 "--incremental-decisions","october_identity_parity/decisions.csv",
 "--output-dir","october_identity_parity/output"),stdout=TRUE,stderr=TRUE))
status<-attr(z,"status");if(!is.null(status)&&status!=0L)stop(paste(z,collapse=" | "))
actual<-fread("october_identity_parity/output/identity_cluster_map.csv",colClasses="character")
actual[,identity:=key(source,source_record_id)]
setkey(actual,identity);setkey(final,identity)
joined<-merge(actual[,.(identity,actual_cluster=cluster_id,actual_size=cluster_size)],
 final[,.(identity,reference_cluster=cluster_id,reference_size=cluster_size)],by="identity")
if(nrow(joined)!=nrow(final))stop("Missing manifestations")
# Compare cluster partitions independently of their labels. A bijection between
# actual and reference cluster IDs proves identical manifestation membership.
bridge<-unique(joined[,.(actual_cluster,reference_cluster)])
actual_splits<-bridge[, .N,by=actual_cluster][N!=1L]
reference_splits<-bridge[, .N,by=reference_cluster][N!=1L]
size_mismatches<-joined[actual_size!=reference_size]
membership_mismatches<-nrow(actual_splits)+nrow(reference_splits)+nrow(size_mismatches)
id_mismatches<-joined[actual_cluster!=reference_cluster]
mismatch<-joined[actual_size!=reference_size |
 actual_cluster%in%actual_splits$actual_cluster |
 reference_cluster%in%reference_splits$reference_cluster]

fwrite(mismatch,"october_identity_parity/mismatches.csv")
report<-list(schema="w01-fast-october-identity-cluster-replay-v1",
 historical=nrow(old),appended=nrow(appended),total=nrow(final),
 reference_derived_duplicate_links=nrow(dec),membership_mismatches=membership_mismatches,
 cluster_id_mismatches=nrow(id_mismatches),clusters_with_label_mapping=nrow(bridge),
 exact_work_id_parity=nrow(id_mismatches)==0L,
 reference_derived_edges=TRUE,independent_matching_validated=FALSE,
 production_publication_allowed=FALSE)
write_json(report,"october_identity_parity/report.json",auto_unbox=TRUE,pretty=TRUE)
if(membership_mismatches || nrow(id_mismatches))
 stop(sprintf("October parity failed: membership=%d, work IDs=%d",membership_mismatches,nrow(id_mismatches)))
cat(sprintf("PASS: October membership parity across %d manifestations; %d cluster-ID label differences (not ID parity)\\n",nrow(final),nrow(id_mismatches)))
