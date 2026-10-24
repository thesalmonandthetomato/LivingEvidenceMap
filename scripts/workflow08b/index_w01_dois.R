#!/usr/bin/env Rscript
# Historical DOI index over ALL W01 canonical records/manifestations.
# Conflict-aware: colliding DOIs are marked ambiguous, never assigned arbitrarily.
suppressPackageStartupMessages(library(jsonlite))
`%||%`<-function(x,y)if(is.null(x))y else x
a<-commandArgs(trailingOnly=TRUE)
if(length(a)!=2L)stop("Usage: index_w01_dois.R canonical_records.jsonl output_dir")
if(!file.exists(a[[1]]))stop("W01 canonical absent")
out<-a[[2]];dir.create(out,recursive=TRUE,showWarnings=FALSE)
norm<-function(x){
 z<-unlist(x,use.names=FALSE)
 if(!length(z))return("")
 v<-tolower(trimws(as.character(z[[1]])))
 v<-sub("^https?://(dx[.])?doi[.]org/","",v)
 sub("^doi:[[:space:]]*","",v)
}
values<-new.env(parent=emptyenv(),hash=TRUE)
add<-function(doi,id){
 if(!nzchar(doi))return()
 z<-if(exists(doi,envir=values,inherits=FALSE))get(doi,envir=values)else character()
 assign(doi,unique(c(z,id)),envir=values)
}
con<-file(a[[1]],"rt");on.exit(close(con))
n<-0L
repeat{
 lines<-readLines(con,n=500L,warn=FALSE)
 if(!length(lines))break
 for(line in lines){
  if(!nzchar(line))next
  z<-fromJSON(line,simplifyVector=FALSE)
  id<-as.character(z$identity$record_id %||% "")
  if(!nzchar(id))stop("Missing W01 record identity")
  add(norm(z$canonical$doi),id)
  for(m in z$manifestations %||% list()){
   add(norm(m$doi),id)
   add(norm(m$manifestation_metadata$identifiers$doi),id)
  }
  n<-n+1L
 }
}
keys<-sort(ls(values,all.names=TRUE))
result<-lapply(keys,function(k){
 ids<-get(k,envir=values)
 data.frame(doi=k,w01_record_ids=paste(sort(ids),collapse="|"),
  identity_status=if(length(ids)==1L)"unique_historical_w01" else "ambiguous_historical_w01",
  stringsAsFactors=FALSE)
})
df<-if(length(result))do.call(rbind,result)else data.frame(
 doi=character(),w01_record_ids=character(),identity_status=character())
write.csv(df,file.path(out,"historical_doi_index.csv"),row.names=FALSE)
info<-list(schema="workflow08b-historical-doi-v1",historical_w01_records=n,
 unique_dois=sum(df$identity_status=="unique_historical_w01"),
 ambiguous_dois=sum(df$identity_status=="ambiguous_historical_w01"))
writeLines(toJSON(info,auto_unbox=TRUE,pretty=TRUE),file.path(out,"summary.json"))
cat("PASS: indexed ",n," W01 works; ambiguous DOI keys=",info$ambiguous_dois,"\n",sep="")
