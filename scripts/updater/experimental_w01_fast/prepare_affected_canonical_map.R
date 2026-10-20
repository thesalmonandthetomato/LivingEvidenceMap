#!/usr/bin/env Rscript
# Stage an identity-safe subset of the successor cluster map for canonicalisation.
# This does NOT call production canonicalisation or modify historical records.
suppressPackageStartupMessages({library(data.table);library(jsonlite);library(digest)})
a<-commandArgs(trailingOnly=TRUE)
arg<-function(k){i<-match(k,a);if(is.na(i)||i==length(a))stop(paste("Missing",k));a[[i+1L]]}
map_path<-arg("--successor-map");affected_path<-arg("--affected-works")
out<-arg("--output-dir")
map<-fread(map_path,colClasses=list(character=c("source","source_record_id","cluster_id")))
affected<-fread(affected_path,colClasses=list(character="cluster_id"))
needed<-c("source","source_record_id","cluster_id")
if(!all(needed%in%names(map))||!all(c("stage","cluster_id")%in%names(affected)))
 stop("Missing required stable-identity fields",call.=FALSE)
if(anyNA(map[,..needed])||anyDuplicated(map[,.(source,source_record_id)])||
   anyNA(affected$cluster_id)||anyDuplicated(affected[,.(stage,cluster_id)]))
 stop("Invalid or ambiguous cluster identities",call.=FALSE)
selected<-affected[stage=="successor",unique(cluster_id)]
if(any(!selected%in%map$cluster_id))stop("Affected successor work has no members",call.=FALSE)
subset<-map[cluster_id%in%selected]
if("cluster_size"%in%names(map)){
 if(any(subset[,uniqueN(source_record_id),by=cluster_id]$V1<1L))stop("Invalid cluster")
}else subset[,cluster_size:=.N,by=cluster_id]
subset<-subset[,.(source,source_record_id,cluster_id,cluster_size)]
setorder(subset,source,source_record_id)
if(dir.exists(out)||file.exists(out))stop("Output already exists",call.=FALSE)
dir.create(out,recursive=TRUE)
fwrite(subset,file.path(out,"affected_cluster_map.csv"))
writeLines(toJSON(list(schema="experimental-w01-fast-canonical-scope-v1",
 affected_successor_works=length(selected),affected_manifestations=nrow(subset),
 successor_map_sha256=digest(file=map_path,algo="sha256"),
 affected_works_sha256=digest(file=affected_path,algo="sha256"),
 production_publication_allowed=FALSE),pretty=TRUE,auto_unbox=TRUE),
 file.path(out,"scope_manifest.json"))
cat(sprintf("PASS: staged %d changed works and %d manifestations\n",length(selected),nrow(subset)))
