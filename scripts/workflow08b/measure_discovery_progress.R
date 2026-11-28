#!/usr/bin/env Rscript
library(jsonlite)
a<-commandArgs(TRUE);stopifnot(length(a)==3L)
root<-a[1];month<-a[2]
stopifnot(grepl("^[0-9]{4}-(0[1-9]|1[0-2])$",month))
count<-function(file,key,accepted){
 p<-file.path(root,file);if(!file.exists(p))return(0L)
 latest<-new.env(hash=TRUE,parent=emptyenv())
 for(line in readLines(p,warn=FALSE)){
  if(!nzchar(trimws(line)))next
  z<-fromJSON(line,simplifyVector=FALSE)
  k<-as.character(z[[key]])
  if(length(k)==1L&&!is.na(k)&&nzchar(k))latest[[k]]<-z
 }
 sum(vapply(as.list(latest),function(z)identical(z$update_id,month)&&isTRUE(z$status%in%accepted),logical(1)))
}
counts<-list(doi=count("lens_doi_resolution.jsonl","doi",c("complete","resolved","not_found")),
 lens=count("lens_seed_status.jsonl","lens_id",c("complete","not_found")),
 openalex=count("openalex_seed_status.jsonl","openalex_id",c("complete","not_found")))
writeLines(toJSON(list(update_month=month,counts=counts,total=sum(unlist(counts))),auto_unbox=TRUE),a[3])
