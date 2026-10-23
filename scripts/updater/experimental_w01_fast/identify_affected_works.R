#!/usr/bin/env Rscript
# Compare prior and successor identity-cluster maps to identify works needing
# canonical rematerialisation. No row offsets, no production writes.
suppressPackageStartupMessages({library(data.table);library(jsonlite);library(digest)})
a<-commandArgs(trailingOnly=TRUE)
arg<-function(k){i<-match(k,a);if(is.na(i)||i==length(a))stop(paste("Missing",k));a[[i+1L]]}
old_path<-arg("--prior-map");next_path<-arg("--next-map");out<-arg("--output-dir"); repairs_path<-arg("--repairs")
readmap<-function(path){
 x<-fread(path,colClasses=list(character=c("source","source_record_id","cluster_id")))
 required<-c("source","source_record_id","cluster_id")
 if(!all(required%in%names(x))||anyNA(x[,..required])||
   any(!nzchar(x$source))||any(!nzchar(x$source_record_id))||
   any(!nzchar(x$cluster_id))||
   anyDuplicated(x[,.(source,source_record_id)]))
   stop("Invalid identity-cluster map",call.=FALSE)
 x[,..required]
}
old<-readmap(old_path);nextmap<-readmap(next_path)
key<-function(x)paste0(nchar(x$source,type="bytes"),":",x$source,
 nchar(x$source_record_id,type="bytes"),":",x$source_record_id)
old[,key:=key(old)];nextmap[,key:=key(nextmap)]
if(any(!old$key%in%nextmap$key))stop("Prior manifestations disappeared",call.=FALSE)
prev_for_new<-setNames(old$cluster_id,old$key)[nextmap$key]
changed<-is.na(prev_for_new)|prev_for_new!=nextmap$cluster_id
# Even if a name is reused incorrectly, changed membership must be detected.
old_members<-old[,.(members=list(sort(key))),by=cluster_id]
new_members<-nextmap[,.(members=list(sort(key))),by=cluster_id]
old_signatures<-setNames(vapply(old_members$members,paste,collapse="\u001f",FUN.VALUE=character(1)),old_members$cluster_id)
new_signatures<-setNames(vapply(new_members$members,paste,collapse="\u001f",FUN.VALUE=character(1)),new_members$cluster_id)
affected_old<-names(old_signatures)[!names(old_signatures)%in%names(new_signatures) |
 vapply(names(old_signatures),function(id)!identical(unname(old_signatures[[id]]),unname(new_signatures[id])),logical(1))]
affected_new<-names(new_signatures)[!names(new_signatures)%in%names(old_signatures) |
 vapply(names(new_signatures),function(id)!identical(unname(new_signatures[[id]]),unname(old_signatures[id])),logical(1))]
# Explicit human repairs can alter canonical content without changing cluster membership.
repair_works<-character()
if(!is.null(repairs_path)){
 if(!file.exists(repairs_path))stop("Approved repair ledger missing")
 lines<-readLines(repairs_path,warn=FALSE,encoding="UTF-8")
 lines<-lines[nzchar(trimws(lines))]
 next_by_key<-setNames(nextmap$cluster_id,nextmap$key)
 for(line in lines){
  z<-fromJSON(line,simplifyVector=FALSE)
  source<-as.character(z$source);record<-as.character(z$source_record_id)
  if(length(source)!=1L||length(record)!=1L||!nzchar(source)||!nzchar(record))
   stop("Repair lacks immutable source identity")
  k<-paste0(nchar(source,type="bytes"),":",source,nchar(record,type="bytes"),":",record)
  work<-next_by_key[[k]]
  if(is.null(work))stop("Approved repair references absent manifestation")
  repair_works<-c(repair_works,work)
 }
}
affected_new<-sort(unique(c(affected_new,repair_works)))
out_rows<-rbindlist(list(
 data.table(stage="prior",cluster_id=affected_old),
 data.table(stage="successor",cluster_id=affected_new)))
setorder(out_rows,stage,cluster_id)
if(dir.exists(out)||file.exists(out))stop("Refusing to overwrite outputs",call.=FALSE)
dir.create(out,recursive=TRUE)
fwrite(out_rows,file.path(out,"affected_works.csv"))
writeLines(toJSON(list(schema="w01-fast-affected-works-v1",
 prior_works=nrow(old_members),successor_works=nrow(new_members),
 affected_prior_works=length(affected_old),affected_successor_works=length(affected_new),\n repair_affected_successor_works=length(unique(repair_works)),
 production_publication_allowed=FALSE),auto_unbox=TRUE,pretty=TRUE),
 file.path(out,"manifest.json"))
cat(sprintf("PASS: %d previous and %d successor works affected\n",length(affected_old),length(affected_new)))
