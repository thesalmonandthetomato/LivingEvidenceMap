#!/usr/bin/env Rscript
suppressPackageStartupMessages({library(httr2);library(jsonlite);library(digest)})
args<-commandArgs(trailingOnly=TRUE)
arg<-function(flag,default=NULL){i<-match(flag,args);if(is.na(i))return(default);if(i==length(args))stop(sprintf("Missing value after %s",flag),call.=FALSE);args[[i+1L]]}
pointer<-arg("--pointer");output<-arg("--output")
if(is.null(pointer)||is.null(output))stop("Required: --pointer --output",call.=FALSE)
x<-fromJSON(pointer,simplifyVector=FALSE)
if(!identical(x$status,"published")||!identical(x$workflow,"08"))stop("Invalid Workflow 08 pointer",call.=FALSE)
files<-x$files
if(is.data.frame(files))files<-lapply(seq_len(nrow(files)),function(i)as.list(files[i,,drop=FALSE]))
if(is.list(files)&&!is.null(files$filename))files<-list(files)
hit<-Filter(function(z)identical(as.character(z$filename),"workflow08_adjudication_ledger.jsonl"),files)
if(length(hit)!=1L)stop("W08 pointer lacks unique adjudication ledger file",call.=FALSE)
token<-Sys.getenv("ZENODO_ACCESS_TOKEN");if(!nzchar(token))stop("ZENODO_ACCESS_TOKEN is not set",call.=FALSE)
z<-hit[[1L]]
url<-paste0("https://zenodo.org/api/records/",x$zenodo_record_id,"/files/",URLencode(as.character(z$filename),reserved=TRUE),"/content")
resp<-request(url)|>req_headers(Authorization=paste("Bearer",token))|>req_timeout(1200)|>req_error(is_error=function(resp)FALSE)|>req_perform()
if(resp_status(resp)!=200L)stop(sprintf("Zenodo ledger download HTTP %d",resp_status(resp)),call.=FALSE)
dir.create(dirname(output),recursive=TRUE,showWarnings=FALSE);writeBin(resp_body_raw(resp),output)
sha<-digest(file=output,algo="sha256",serialize=FALSE)
if(!identical(tolower(sha),tolower(as.character(z$sha256))))stop("W08 ledger checksum mismatch",call.=FALSE)
cat(sprintf("PASS: restored W08 adjudication ledger from Zenodo record %s\n",x$zenodo_record_id))
