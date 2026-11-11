#!/usr/bin/env Rscript
suppressPackageStartupMessages({library(data.table);library(jsonlite)})
a<-commandArgs(trailingOnly=TRUE);arg<-function(k){i<-match(k,a);if(is.na(i)||i==length(a))stop("Missing ",k);a[[i+1L]]}
root<-arg("--previous-root");out<-arg("--output-dir")
m<-fread(file.path(root,"workflow01_full_five_source","manifestation_cluster_map.csv"),
colClasses=list(character=c("source","source_record_id")))
p<-fread(file.path(root,"workflow01_full_five_source","final_pair_decisions.csv"))
if(!all(c("idx","source","source_record_id")%in%names(m))||
 !all(c("record_i","record_j","source_i","source_j")%in%names(p)))
 stop("Missing authoritative prior-map/decision schema")
if(!identical(as.integer(m$idx),seq_len(nrow(m))))stop("Prior manifestation index invalid")
dir.create(out,recursive=TRUE,showWarnings=FALSE)
issues<-list();total<-0L
for(side in c("i","j")){
 ix<-as.integer(p[[paste0("record_",side)]])
 if(anyNA(ix)||any(ix<1L|ix>nrow(m)))stop("Previous ledger contains out-of-bounds historic index")
 for(field in c("source", "source_record_id")){
  col<-paste0(field,"_",side)
  if(!col%in%names(p))next
  expected<-m[[field]][ix];actual<-p[[col]]
  bad<-which(is.na(actual)|actual!=expected)
  total<-total+length(bad)
  issues[[col]]<-list(mismatches=length(bad),examples=lapply(head(bad,12L),function(j)
   list(row=j,record_i=as.character(p$record_i[j]),
    record_j=as.character(p$record_j[j]),recorded=as.character(actual[j]),
    mapped=as.character(expected[j]))))
 }
}
write_json(list(schema="w01-fast-prior-state-pair-index-audit-v1",
 prior_manifestations=nrow(m),prior_decisions=nrow(p),
 mismatch_fields=total,by_column=issues,publication_allowed=FALSE),
 file.path(out,"report.json"),pretty=TRUE,auto_unbox=TRUE)
cat(sprintf("AUDIT: %d original pairs; %d mismatched legacy source identity fields\\n",nrow(p),total))
# This audit reports inconsistencies to determine repair; it never approves merging.
