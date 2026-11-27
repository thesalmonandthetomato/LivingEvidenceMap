#!/usr/bin/env Rscript
# Verify final W08 acceptance and select a recoverable W09 handoff.
# No API calls or writes to production state.
suppressPackageStartupMessages(library(jsonlite))
w09_handoff <- function(status,release,marker,registry,runs=list()){
 scalar<-function(x){z<-as.character(unlist(x,use.names=FALSE));if(length(z)!=1L||is.na(z)||!nzchar(z))stop("Invalid handoff identity");z}
 u<-scalar(release$update_id);r<-scalar(release$w08_run_id);h<-tolower(scalar(release$w08_canonical_sha256));m<-scalar(release$update_month)
 stopifnot(grepl("^[A-Za-z0-9._-]+$",u),grepl("^[0-9]+$",r),grepl("^[a-f0-9]{64}$",h),
 identical(status$branch,"workflow01-final-architecture"),identical(scalar(status$update_id),u),
 identical(scalar(status$workflow_runs$W08),r),identical(marker$schema,"workflow08b-monthly-routing-state-v1"),
 identical(marker$stage,"completed"),identical(scalar(marker$update_id),u),identical(scalar(marker$update_month),m),
 identical(scalar(marker$final_w08_run_id),r),identical(tolower(scalar(marker$final_w08_sha256)),h),
 identical(registry$schema,"workflow08b-monthly-checkpoint-registry-v1"))
 z<-Filter(function(x)identical(x$month,m),registry$checkpoints)
 stopifnot(length(z)==1L,identical(z[[1]]$status,"verified_archive"),
 identical(scalar(z[[1]]$post_chasing_w08_source_run_id),r),identical(tolower(scalar(z[[1]]$post_chasing_w08_sha256)),h))
 n<-as.integer(scalar(status$progress$completed_through))
 stopifnot(n%in%9:11)
 label<-paste0("W09 release ",u," / ",r," / ",h)
 if(n>=10L)return(list(action="complete",title=label))
 matching<-Filter(function(x)identical(x$displayTitle,label),runs)
 if(any(vapply(matching,function(x)!identical(x$status,"completed"),logical(1))))return(list(action="await",title=label))
 if(any(vapply(matching,function(x)identical(x$conclusion,"success"),logical(1))))stop("Successful W09 run conflicts with incomplete committed status; inspect before retry")
 list(action="dispatch",title=label)
}
if(sys.nframe()==0L){
 a<-commandArgs(TRUE);if(length(a)!=6L)stop("Expected status, release, routing marker, registry, runs, output")
 x<-lapply(a[1:5],fromJSON,simplifyVector=FALSE)
 z<-do.call(w09_handoff,x)
 writeLines(toJSON(z,auto_unbox=TRUE,pretty=TRUE),a[[6]])
 cat("PASS: W09 handoff action ",z$action,"\n",sep="")
}
