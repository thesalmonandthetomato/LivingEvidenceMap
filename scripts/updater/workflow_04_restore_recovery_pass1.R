#!/usr/bin/env Rscript
suppressPackageStartupMessages({library(httr2);library(jsonlite);library(digest)})
args<-commandArgs(trailingOnly=TRUE)
arg<-function(flag,default=NULL){i<-match(flag,args);if(is.na(i))return(default);if(i==length(args))stop(sprintf("Missing value after %s",flag),call.=FALSE);args[[i+1L]]}
record_id<-arg("--zenodo-record-id");out<-arg("--output-dir")
if(is.null(record_id)||is.null(out))stop("Required: --zenodo-record-id --output-dir",call.=FALSE)
token<-Sys.getenv("ZENODO_ACCESS_TOKEN");if(!nzchar(token))stop("ZENODO_ACCESS_TOKEN required",call.=FALSE)
dir.create(out,recursive=TRUE,showWarnings=FALSE)
auth<-function(req)req|>req_headers(Authorization=paste("Bearer",token))
dep<-request(paste0("https://zenodo.org/api/deposit/depositions/",record_id))|>auth()|>req_timeout(120)|>req_perform()|>resp_body_json(simplifyVector=FALSE)
if(!isTRUE(dep$submitted))stop("Recovery Zenodo record is not published",call.=FALSE)
bucket<-as.character(dep$links$bucket)
fns<-vapply(dep$files,function(z)as.character(z$filename),character(1))
archive_fn<-fns[grepl("\\.tar\\.gz$",fns)]
manifest_fn<-fns[grepl("recovery_manifest\\.json$",fns)]
if(length(archive_fn)!=1L||length(manifest_fn)!=1L)stop("Unexpected recovery record file set",call.=FALSE)
download<-function(fn,dest){
  resp<-request(paste0(sub("/$","",bucket),"/",URLencode(fn,reserved=TRUE)))|>req_method("GET")|>auth()|>req_timeout(1200)|>req_error(is_error=function(resp)FALSE)|>req_perform(path=dest)
  if(resp_status(resp)!=200L)stop(sprintf("Recovery download failed for %s",fn),call.=FALSE)
}
archive<-file.path(out,archive_fn);manifest_path<-file.path(out,manifest_fn);download(archive_fn,archive);download(manifest_fn,manifest_path)
m<-fromJSON(manifest_path,simplifyVector=FALSE)
if(!identical(as.character(m$schema),"living-evidence-map-workflow04-recovery-checkpoint-v1"))stop("Unexpected recovery manifest schema",call.=FALSE)
ex<-file.path(out,"extract");dir.create(ex,showWarnings=FALSE);utils::untar(archive,exdir=ex)
hits<-list.files(ex,pattern="^salvaged_new_pass1\\.jsonl$",recursive=TRUE,full.names=TRUE)
if(length(hits)!=1L)stop("Could not locate salvaged_new_pass1.jsonl",call.=FALSE)
dest<-file.path(out,"salvaged_new_pass1.jsonl");file.copy(hits[[1]],dest,overwrite=TRUE)
sha<-digest(file=dest,algo="sha256",serialize=FALSE)
if(!identical(tolower(sha),tolower(as.character(m$salvage_sha256))))stop("Recovered pass-1 SHA mismatch",call.=FALSE)
n<-length(Filter(nzchar,trimws(readLines(dest,warn=FALSE,encoding="UTF-8"))))
if(n!=as.integer(m$salvaged_new_record_pass1_rows))stop("Recovered pass-1 row count mismatch",call.=FALSE)
cat(sprintf("PASS: restored %d reusable W04 pass-1 decisions from restricted Zenodo record %s\n",n,record_id))
