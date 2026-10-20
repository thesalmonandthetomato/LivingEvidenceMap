#!/usr/bin/env Rscript
# Scientific reference audit using frozen October W01 maps, without rerunning W01.
suppressPackageStartupMessages({library(data.table);library(jsonlite);library(digest)})
a<-commandArgs(trailingOnly=TRUE)
root<-if(length(a)) a[[1L]] else "reference"
old_path<-file.path(root,"previous_state/workflow01_full_five_source/manifestation_cluster_map.csv")
new_path<-file.path(root,"outputs/final/manifestation_cluster_map.csv")
if(!file.exists(old_path)||!file.exists(new_path))stop("Missing frozen October maps")
load<-function(path){
 x<-fread(path,colClasses=list(character=c("source","source_record_id","cluster_id","cluster_id_origin")))
 need<-c("source","source_record_id","cluster_id","cluster_size")
 if(!all(need%in%names(x))||anyNA(x[,..need])||
 any(!nzchar(x$source)|!nzchar(x$source_record_id)|!nzchar(x$cluster_id))||
 anyDuplicated(x[,.(source,source_record_id)]))stop("Invalid manifestation identities")
 x[,key:=paste0(nchar(source,type="bytes"),":",source,
                 nchar(source_record_id,type="bytes"),":",source_record_id)]
 if(anyDuplicated(x$key))stop("Length-prefixed identity collision")
 if(anyNA(x$cluster_size)||any(x$cluster_size<1L))stop("Bad cluster sizes")
 # Every member of a cluster must report the actual total membership.
 counts<-x[,.(true_size=.N),by=cluster_id]
 x[counts,on="cluster_id",true_size:=i.true_size]
 if(any(x$cluster_size!=x$true_size))stop("Cluster-size metadata inconsistent")
 x
}
old<-load(old_path);nextmap<-load(new_path)
lost<-old[!key%in%nextmap$key]
if(nrow(lost))stop("Historical manifestations disappeared")
matched<-merge(old,nextmap,by="key",suffixes=c("_old","_new"),sort=FALSE)
if(nrow(matched)!=nrow(old))stop("Incomplete historical matching")
if(any(matched$cluster_id_old!=matched$cluster_id_new))
 stop("Historical work identities unexpectedly reassigned")
appended<-nextmap[!key%in%old$key]
prior_ids<-unique(old$cluster_id)
final_ids<-unique(nextmap$cluster_id)
new_works<-setdiff(final_ids,prior_ids)
retired<-setdiff(prior_ids,final_ids)
attached<-sum(appended$cluster_id%in%prior_ids)
if(length(retired))stop("Unexplained retired historical work IDs")
if(any(!appended$cluster_id%in%c(prior_ids,new_works)))stop("Unknown cluster")
result<-list(schema="w01-fast-october-real-cluster-reference-v1",
 prior_manifestations=nrow(old),final_manifestations=nrow(nextmap),
 prior_works=length(prior_ids),final_works=length(final_ids),
 appended_manifestations=nrow(appended),
 retained_historical_manifestations=nrow(matched),
 historical_manifestations_reassigned=0L,
 appended_to_existing_works=attached,
 new_works=length(new_works),
 new_manifestations_by_source=as.list(table(appended$source)),
 prior_sha256=digest(file=old_path,algo="sha256"),
 final_sha256=digest(file=new_path,algo="sha256"),
 parity_reference_verified=TRUE,
 w01_fast_full_parity_established=FALSE)
dir.create("real_parity_report",showWarnings=FALSE)
write_json(result,"real_parity_report/october_cluster_reference.json",
 pretty=TRUE,auto_unbox=TRUE)
cat(sprintf("PASS: October reference %d old + %d new manifestations; %d new works; %d appended to historical works; 0 historical reassignments\n",
 nrow(old),nrow(appended),length(new_works),attached))
