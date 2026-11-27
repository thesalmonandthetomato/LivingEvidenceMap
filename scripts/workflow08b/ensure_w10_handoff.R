#!/usr/bin/env Rscript
suppressPackageStartupMessages(library(jsonlite))
w10_handoff <- function(status,release,pointer,summary,runs=list()){
 scalar<-function(x){z<-as.character(unlist(x,use.names=FALSE));if(length(z)!=1L||is.na(z)||!nzchar(z))stop("Invalid release scalar");z}
 u<-scalar(release$update_id);r<-scalar(release$w08_run_id);h<-tolower(scalar(release$w08_canonical_sha256))
 stopifnot(grepl("^[A-Za-z0-9._-]+$",u),grepl("^[0-9]+$",r),grepl("^[a-f0-9]{64}$",h),
 identical(status$branch,"workflow01-final-architecture"),identical(scalar(status$update_id),u),
 identical(scalar(status$workflow_runs$W08),r),identical(status$progress$W09$status,"complete"),
 grepl("^[0-9]+$",scalar(status$workflow_runs$W09)),
 identical(pointer$status,"published"),identical(scalar(pointer$source_github_run_id),r),
 identical(tolower(scalar(pointer$final_canonical_jsonl_sha256)),h),
 identical(scalar(summary$source_run_id),r),identical(tolower(scalar(summary$metrics$final_canonical_sha256)),h))
 n<-as.integer(scalar(status$progress$completed_through));stopifnot(n%in%10:11)
 label<-paste0("W10 release ",u," / ",r," / ",h)
 if(n==11L){stopifnot(identical(status$progress$W10$status,"complete"));return(list(action="complete",title=label))}
 matching<-Filter(function(x)identical(x$displayTitle,label),runs)
 if(any(vapply(matching,function(x)!identical(x$status,"completed"),logical(1))))return(list(action="await",title=label))
 if(any(vapply(matching,function(x)identical(x$conclusion,"success"),logical(1))))stop("Successful W10 conflicts with incomplete committed status; inspect before retry")
 list(action="dispatch",title=label)
}
if(sys.nframe()==0L){
 a<-commandArgs(TRUE);stopifnot(length(a)==6L)
 z<-do.call(w10_handoff,lapply(a[1:5],fromJSON,simplifyVector=FALSE))
 writeLines(toJSON(z,auto_unbox=TRUE,pretty=TRUE),a[[6]])
}
