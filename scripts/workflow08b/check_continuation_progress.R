#!/usr/bin/env Rscript
library(jsonlite)
check_continuation<-function(status,start,end,receipt,attempt){
 stopifnot(identical(status$provider_discovery_complete,FALSE),
 is.numeric(status$queries_remaining),length(status$queries_remaining)==1L,
 is.finite(status$queries_remaining),status$queries_remaining>0,
 identical(status$update_month,start$update_month),identical(start$update_month,end$update_month),
 receipt$status%in%c("draft","published"),grepl("^[0-9]+$",receipt$zenodo_record_id),
 grepl("^[a-f0-9]{64}$",receipt$sha256),
 length(attempt)==1L,is.finite(attempt),attempt>=0,attempt<12,attempt==as.integer(attempt),
 identical(names(start$counts),names(end$counts)),all(unlist(end$counts)>=unlist(start$counts)),
 start$total==sum(unlist(start$counts)),end$total==sum(unlist(end$counts)),
 end$total>start$total)
 invisible(TRUE)
}
if(sys.nframe()==0L){
 a<-commandArgs(TRUE);stopifnot(length(a)==5L)
 x<-lapply(a[1:4],fromJSON,simplifyVector=FALSE)
 do.call(check_continuation,c(x,list(as.integer(a[5]))))
 cat("PASS: checkpoint archived with positive progress; bounded continuation authorised\n")
}
