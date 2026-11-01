#!/usr/bin/env Rscript
# Recombine unchanged prior canonical records with newly generated affected works.
# This is an isolated staging tool, never a production publisher.
suppressPackageStartupMessages({library(jsonlite);library(data.table);library(digest)})
a<-commandArgs(trailingOnly=TRUE)
arg<-function(k){i<-match(k,a);if(is.na(i)||i==length(a))stop(paste("Missing",k));a[[i+1L]]}
prior_path<-arg("--prior");changed_path<-arg("--changed")
affected_path<-arg("--affected-works");out<-arg("--output-dir")
if(file.exists(out)||dir.exists(out))stop("Refusing to overwrite destination")
read_records<-function(path){
 lines<-readLines(path,warn=FALSE,encoding="UTF-8")
 lines<-lines[nzchar(trimws(lines))]
 obj<-lapply(lines,function(line)fromJSON(line,simplifyVector=FALSE))
 ids<-vapply(obj,function(r){
  id<-r$identity$record_id
  if(!identical(r$schema_version,"living-evidence-map-canonical-v1")||
   !identical(r$identity$record_id_type,"deduplication_cluster_id")||
   !is.character(id)||length(id)!=1L||is.na(id)||!nzchar(id))
   stop("Invalid canonical record identity")
  id
 },character(1))
 if(anyDuplicated(ids))stop("Duplicate canonical record ID")
 setNames(lines,ids)
}
prior<-read_records(prior_path);changed<-read_records(changed_path)
affected<-fread(affected_path,colClasses=list(character="cluster_id"))
if(!all(c("stage","cluster_id")%in%names(affected))||
 anyNA(affected[,.(stage,cluster_id)])||
 any(!affected$stage%in%c("prior","successor"))||
 anyDuplicated(affected[,.(stage,cluster_id)]))
 stop("Invalid affected-work manifest")
old_ids<-affected[stage=="prior",cluster_id]
new_ids<-affected[stage=="successor",cluster_id]
if(!all(old_ids%in%names(prior)))stop("Affected historical works absent from prior records")
if(!setequal(names(changed),new_ids)||length(changed)!=length(new_ids))
 stop("Regenerated work IDs do not exactly match affected successors")
retained<-prior[!names(prior)%in%old_ids]
if(any(names(changed)%in%names(retained)))stop("Canonical ID collision with untouched history")
assembled<-c(retained,changed)
if(anyDuplicated(names(assembled)))stop("Duplicate result ID")
dir.create(out,recursive=TRUE)
outfile<-file.path(out,"canonical.jsonl")
writeLines(unname(assembled[order(names(assembled))]),outfile,useBytes=TRUE)
writeLines(toJSON(list(schema="experimental-w01-fast-canonical-recombination-v1",
 prior_works=length(prior),retained_unmodified_works=length(retained),
 replaced_prior_works=length(old_ids),regenerated_successor_works=length(new_ids),
 successor_works=length(assembled),production_publication_allowed=FALSE,
 output_sha256=digest(file=outfile,algo="sha256")),auto_unbox=TRUE,pretty=TRUE),
 file.path(out,"recombination_audit.json"))
cat(sprintf("PASS: retained %d historical works and inserted %d regenerated works\n",
 length(retained),length(changed)))
