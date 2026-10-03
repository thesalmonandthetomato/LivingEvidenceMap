#!/usr/bin/env Rscript
suppressPackageStartupMessages({library(jsonlite);library(digest)})

args<-commandArgs(trailingOnly=TRUE)
arg<-function(flag,default=NULL){i<-match(flag,args);if(is.na(i))return(default);if(i==length(args))stop(sprintf("Missing value after %s",flag),call.=FALSE);args[[i+1L]]}
canonical_path<-arg("--canonical")
review_path<-arg("--human-review")
output_dir<-arg("--output-dir")
source_run_id<-arg("--source-run-id")
if(any(vapply(list(canonical_path,review_path,output_dir,source_run_id),is.null,logical(1))))stop("Required: --canonical --human-review --output-dir --source-run-id",call.=FALSE)

`%||%`<-function(x,y)if(is.null(x))y else x
scalar<-function(x){if(is.null(x)||!length(x))return("");z<-as.character(x[[1L]]);if(is.na(z))"" else trimws(z)}
textify<-function(x){
  if(is.null(x))return("")
  if(is.character(x))return(paste(x[nzchar(x)],collapse="; "))
  if(is.atomic(x))return(paste(as.character(x),collapse="; "))
  if(is.list(x))return(paste(Filter(nzchar,vapply(x,textify,character(1))),collapse="; "))
  as.character(x)
}
first_nonempty<-function(...){for(x in list(...)){z<-textify(x);if(nzchar(trimws(z)))return(trimws(z))};""}
read_jsonl<-function(path){x<-readLines(path,warn=FALSE,encoding="UTF-8");x<-x[nzchar(trimws(x))];lapply(x,function(z)fromJSON(z,simplifyVector=FALSE))}
rid<-function(r)scalar((r$identity%||%list())$record_id)

canonical<-read_jsonl(canonical_path)
review<-read_jsonl(review_path)
cids<-vapply(canonical,rid,character(1))
if(any(!nzchar(cids))||anyDuplicated(cids))stop("Canonical record_id invariant failed",call.=FALSE)
cmap<-setNames(canonical,cids)
rids<-vapply(review,function(z)scalar(z$record_id),character(1))
if(any(!nzchar(rids))||anyDuplicated(rids))stop("Review queue record_id invariant failed",call.=FALSE)
if(length(setdiff(rids,cids)))stop("Review queue contains IDs absent from canonical",call.=FALSE)
if(!all(vapply(review,function(z)identical(scalar((z$screening%||%list())$decision),"uncertain"),logical(1))))stop("Resolution queue may contain only uncertain W04 records",call.=FALSE)

ord<-order(rids)
review<-review[ord];rids<-rids[ord]
cases<-lapply(seq_along(review),function(i){
  id<-rids[[i]]
  r<-cmap[[id]]; c<-r$canonical%||%list()
  list(
    schema="living-evidence-map-workflow04-resolution-case-v1",
    review_case_id=paste0("w04-resolution-",id),
    record_id=id,
    review_mode="resolution",
    bibliographic=list(
      title=first_nonempty(c$title,r$title),
      authors=first_nonempty(c$authors,c$author,r$authors,r$author),
      year=first_nonempty(c$year,c$publication_year,r$year,r$publication_year),
      journal=first_nonempty(c$source_title,c$journal,r$source_title,r$journal),
      volume=first_nonempty(c$volume,r$volume),
      pages=first_nonempty(c$pages,c$page,r$pages,r$page),
      doi=first_nonempty(c$doi,r$doi),
      abstract=first_nonempty(c$abstract,r$abstract),
      keywords=first_nonempty(c$keywords,r$keywords)
    ),
    screening=review[[i]]$screening
  )
})
dir.create(output_dir,recursive=TRUE,showWarnings=FALSE)
queue_path<-file.path(output_dir,"workflow04_resolution_queue.jsonl")
con<-file(queue_path,"wt",encoding="UTF-8");on.exit(close(con),add=TRUE)
for(z in cases)writeLines(toJSON(z,auto_unbox=TRUE,null="null",na="null",digits=NA),con,useBytes=TRUE)
close(con);on.exit(NULL,add=FALSE)
sha<-digest(file=queue_path,algo="sha256",serialize=FALSE)
manifest<-list(
  schema="living-evidence-map-workflow04-resolution-queue-v1",
  status="PASS",review_mode="resolution",source_run_id=as.character(source_run_id),
  records=length(cases),queue_sha256=sha,
  canonical_sha256=digest(file=canonical_path,algo="sha256",serialize=FALSE),
  human_review_sha256=digest(file=review_path,algo="sha256",serialize=FALSE),
  generated_at_utc=format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ")
)
writeLines(toJSON(manifest,auto_unbox=TRUE,pretty=TRUE,null="null"),file.path(output_dir,"workflow04_resolution_queue_manifest.json"),useBytes=TRUE)
cat(sprintf("PASS: built W04 resolution queue with %d records; sha=%s\n",length(cases),sha))
