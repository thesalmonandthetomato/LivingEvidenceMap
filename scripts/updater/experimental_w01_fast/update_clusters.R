#!/usr/bin/env Rscript
# Experimental W01-Fast: extend immutable historical clusters with newly approved
# duplicate edges. Never writes to production or modifies preserved decisions.
suppressPackageStartupMessages({library(data.table);library(digest);library(jsonlite)})
args <- commandArgs(trailingOnly=TRUE)
arg <- function(x) {i<-match(x,args);if(is.na(i)||i==length(args))stop(paste("Missing",x));args[[i+1L]]}
prior_path<-arg("--prior-map");metadata_path<-arg("--metadata")
decisions_path<-arg("--incremental-decisions");output_dir<-arg("--output-dir")
prior<-fread(prior_path);meta<-fread(metadata_path);dec<-fread(decisions_path)
stopifnot(all(c("idx","source","source_record_id","cluster_id")%in%names(prior)),
          all(c("idx","source","source_record_id")%in%names(meta)),
          all(c("record_i","record_j","rescored_classification")%in%names(dec)))
setorder(prior,idx);setorder(meta,idx)
prior_n<-nrow(prior);n<-nrow(meta)
stopifnot(identical(as.integer(meta$idx),seq_len(n)),
          identical(as.integer(prior$idx),seq_len(prior_n)),
          prior_n<=n,identical(as.character(prior$source),as.character(meta$source[seq_len(prior_n)])),
          identical(as.character(prior$source_record_id),as.character(meta$source_record_id[seq_len(prior_n)])),
          !anyNA(prior$cluster_id),!anyDuplicated(paste(meta$source,meta$source_record_id,sep="::")))
if(nrow(dec)){
  stopifnot(!anyNA(dec$record_i),!anyNA(dec$record_j),
            all(dec$record_i>=1L & dec$record_i<dec$record_j & dec$record_j<=n),
            !any(dec$record_i<=prior_n & dec$record_j<=prior_n))
  if(anyDuplicated(paste(dec$record_i,dec$record_j)))stop("Duplicate incremental decisions")
}
# The prior map is authoritative: start with existing components instead of
# rereading/reclustering 1.6 million preserved historical decisions.
parent<-seq_len(n);rank<-integer(n)
root<-function(i){while(parent[[i]]!=i){parent[[i]]<<-parent[[parent[[i]]]];i<-parent[[i]]};i}
merge_nodes<-function(i,j){
 a<-root(i);b<-root(j);if(a==b)return(invisible(NULL))
 if(rank[[a]]<rank[[b]])parent[[a]]<<-b
 else if(rank[[a]]>rank[[b]])parent[[b]]<<-a
 else{parent[[b]]<<-a;rank[[a]]<<-rank[[a]]+1L}
}
if(prior_n){
  groups<-split(prior$idx,prior$cluster_id)
  for(ids in groups)if(length(ids)>1L)for(j in ids[-1L])merge_nodes(ids[[1L]],j)
}
dup<-dec[rescored_classification=="duplicate"]
if(nrow(dup))for(k in seq_len(nrow(dup)))merge_nodes(dup$record_i[[k]],dup$record_j[[k]])
roots<-vapply(seq_len(n),root,integer(1));groups<-split(seq_len(n),roots)
ids<-character(n);sizes<-integer(n)
for(g in groups){
  keys<-paste(meta$source[g],meta$source_record_id[g],sep=":")
  cid<-paste0("work-",substr(digest(paste(sort(keys),collapse="|"),algo="sha256",serialize=FALSE),1,16))
  ids[g]<-cid;sizes[g]<-length(g)
}
result<-meta[,.(idx,source,source_record_id)]
result[,cluster_id:=ids];result[,cluster_size:=sizes]
dir.create(output_dir,recursive=TRUE,showWarnings=FALSE)
fwrite(result,file.path(output_dir,"manifestation_cluster_map.csv"))
prior_changed<-sum(result$cluster_id[seq_len(prior_n)]!=prior$cluster_id)
writeLines(toJSON(list(schema="experimental-w01-fast-incremental-clusters-v1",
  historical_manifestations=prior_n,new_manifestations=n-prior_n,
  incremental_decisions=nrow(dec),new_duplicate_edges=nrow(dup),
  clusters=length(groups),historical_rows_changed_cluster_id=prior_changed,
  production_publication_allowed=FALSE),pretty=TRUE,auto_unbox=TRUE),
  file.path(output_dir,"summary.json"))
cat(sprintf("W01-FAST: %d clusters, %d new duplicate edges, %d historical cluster IDs affected\n",
 length(groups),nrow(dup),prior_changed))
