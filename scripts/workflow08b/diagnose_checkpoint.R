#!/usr/bin/env Rscript
# W08b diagnostic: read saved restricted checkpoint, no Lens calls or W01 restore.
suppressPackageStartupMessages({library(httr2);library(jsonlite)})
token<-Sys.getenv("ZENODO_ACCESS_TOKEN","");if(!nzchar(token))stop("Missing token")
id<-"23623250"
api<-paste0("https://zenodo.org/api/deposit/depositions/",id)
req<-request(api)|>req_headers(Authorization=paste("Bearer",token))|>req_timeout(60)|>req_perform()
dep<-resp_body_json(req,simplifyVector=FALSE)
files<-dep$files
if(!length(files))stop("No files found in Zenodo checkpoint")
item<-Filter(function(x)grepl("w08b-discovery-run-",as.character(x$filename)),files)
if(length(item)!=1L)stop("Checkpoint archive not uniquely found")
archive<-tempfile(fileext=".tar.gz")
url<-paste0(dep$links$bucket,"/",URLencode(as.character(item[[1]]$filename),reserved=TRUE))
response<-request(url)|>req_headers(Authorization=paste("Bearer",token))|>req_timeout(120)|>req_perform(path=archive)
if(resp_status(response)!=200L)stop("Archive download failed")
root<-tempfile("w08b-checkpoint-");dir.create(root)
utils::untar(archive,exdir=root)
ledger<-file.path(root,"lens_seed_status.jsonl")
if(!file.exists(ledger))stop("Checkpoint ledger missing")
records<-lapply(readLines(ledger,warn=FALSE),function(x)fromJSON(x,simplifyVector=FALSE))
current<-list()
for(x in records)current[[as.character(x$record_id)]]<-x
fail<-Filter(function(x)!identical(x$status,"complete"),current)
cat("Archived checkpoint:",id,"; seeds:",length(current),"; incomplete:",length(fail),"\n")
for(x in fail){
 cat(toJSON(list(record_id=x$record_id,lens_id=x$lens_id,
  reference_count=x$reference_count,backward_ids=x$backward_ids,
  scholarly_citations_count=x$scholarly_citations_count,forward_ids=x$forward_ids,
  error=x$error),auto_unbox=TRUE,null="null"),"\n")
}
