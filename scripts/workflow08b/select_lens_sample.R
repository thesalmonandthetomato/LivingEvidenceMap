#!/usr/bin/env Rscript
# Deterministic spread of Lens-ID seeds across the full W08 included population.
# Excludes seeds already recorded in the restored restricted checkpoint.
suppressPackageStartupMessages(library(jsonlite))
a<-commandArgs(trailingOnly=TRUE)
if(length(a)!=4L)stop("Usage: select_lens_sample.R <full_crosswalk.csv> <checkpoint_ledger.jsonl> <n> <out.csv>")
d<-read.csv(a[[1]],stringsAsFactors=FALSE,na.strings=NULL)
n<-as.integer(a[[3]])
if(is.na(n)||n<1L||n>100L)stop("Sample cap is 100")
stopifnot(all(c("record_id","lens_id","preferred_route","identifier_conflict")%in%names(d)))
seen<-character()
if(file.exists(a[[2]])){
  z<-readLines(a[[2]],warn=FALSE)
  seen<-unique(vapply(z[nzchar(z)],function(x)as.character(fromJSON(x)$record_id),character(1)))
}
d<-d[d$preferred_route=="lens" & !d$identifier_conflict &
  nzchar(d$lens_id) & !grepl("|",d$lens_id,fixed=TRUE) &
  !d$record_id%in%seen,,drop=FALSE]
d<-d[order(d$record_id),,drop=FALSE]
if(nrow(d)<n)stop("Insufficient independent Lens seeds")
idx<-unique(as.integer(round(seq(1,nrow(d),length.out=n))))
if(length(idx)!=n)stop("Sample selection failed")
z<-d[idx,,drop=FALSE]
write.csv(z,a[[4]],row.names=FALSE,quote=TRUE)
cat("PASS: selected ",n," non-overlapping Lens seed records from ",nrow(d)," eligible seeds; no requests made\n",sep="")
