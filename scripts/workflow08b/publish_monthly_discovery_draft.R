#!/usr/bin/env Rscript
# Publish only the committed, remotely verified complete checkpoint.
suppressPackageStartupMessages({library(jsonlite);library(httr2)})
a<-commandArgs(TRUE);stopifnot(length(a)==3L)
p<-fromJSON(a[1],simplifyVector=FALSE);s<-fromJSON(a[2],simplifyVector=FALSE);r<-fromJSON(a[3],simplifyVector=FALSE)
stopifnot(identical(p$schema,"workflow08b-monthly-draft-pointer-v1"),
 identical(s$schema,"workflow08b-monthly-discovery-check-v1"),
 isTRUE(s$provider_discovery_complete),identical(as.integer(s$queries_remaining),0L),
 identical(p$update_month,s$update_month),identical(p$w08_canonical_sha256,s$w08_canonical_sha256),
 identical(p$zenodo_record_id,r$zenodo_record_id),identical(p$sha256,r$sha256),
 identical(p$archive_filename,r$archive_filename),identical(p$md5,r$md5),
 grepl("^[0-9]+$",p$zenodo_record_id),grepl("^[a-f0-9]{64}$",p$sha256),
 grepl("^[a-f0-9]{32}$",p$md5),
 endsWith(p$archive_filename,paste0("-",p$sha256,".tar.gz")),
 p$status%in%c("draft","published"),r$status%in%c("draft","published"))
token<-Sys.getenv("ZENODO_ACCESS_TOKEN");stopifnot(nzchar(token))
url<-paste0("https://zenodo.org/api/deposit/depositions/",p$zenodo_record_id)
req<-function(u,method="GET")request(u)|>req_method(method)|>req_headers(Authorization=paste("Bearer",token))|>req_timeout(120)
getdep<-function()resp_body_json(req_perform(req(url)|>req_retry(max_tries=3)),simplifyVector=FALSE)
check<-function(d){
 stopifnot(identical(as.character(d$id),p$zenodo_record_id),
 identical(d$metadata$title,paste("Living Evidence Map W08b monthly discovery",p$update_month)),
 identical(d$metadata$access_right,"restricted"),
 grepl(paste0("W08b release identity: ",p$update_month," / ",p$w08_canonical_sha256),d$metadata$description,fixed=TRUE))
 files<-Filter(function(x)identical(x$filename,p$archive_filename),d$files)
 stopifnot(length(files)==1L)
 md5<-sub("^md5:","",tolower(as.character(files[[1]]$checksum)))
 stopifnot(identical(md5,p$md5))
}
d<-getdep();check(d)
if(!isTRUE(d$submitted)){
 for(x in d$files){
  if(identical(x$filename,p$archive_filename))next
  stopifnot(grepl("^w08b-discovery-run-.*[.]tar[.]gz$",x$filename))
  z<-req_perform(req(paste0(url,"/files/",x$id),"DELETE"))
  stopifnot(resp_status(z)%in%c(200L,204L))
 }
 d<-getdep();check(d);stopifnot(length(d$files)==1L)
 # A lost publish response must not create a replacement deposition.
 invisible(tryCatch(req_perform(req(paste0(url,"/actions/publish"),"POST")),error=identity))
 d<-getdep();check(d)
}
stopifnot(isTRUE(d$submitted),length(d$files)==1L)
p$status<-"published";r$status<-"published"
writeLines(toJSON(p,auto_unbox=TRUE,pretty=TRUE),a[1])
writeLines(toJSON(r,auto_unbox=TRUE,pretty=TRUE),a[3])
cat("PASS: published one verified restricted monthly checkpoint ",p$zenodo_record_id,"\n",sep="")
