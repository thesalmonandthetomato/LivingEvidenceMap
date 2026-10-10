#!/usr/bin/env Rscript
suppressPackageStartupMessages({library(httr2);library(jsonlite);library(digest)})

args<-commandArgs(trailingOnly=TRUE)
arg<-function(flag,default=NULL){i<-match(flag,args);if(is.na(i))return(default);if(i==length(args))stop(sprintf("Missing value after %s",flag),call.=FALSE);args[[i+1L]]}
pointer<-arg("--pointer");output_dir<-arg("--output-dir")
if(is.null(pointer)||is.null(output_dir))stop("Required: --pointer --output-dir",call.=FALSE)
x<-fromJSON(pointer,simplifyVector=FALSE)
if(!identical(x$status,"published")||!identical(x$workflow,"06")||!identical(x$state,"semantic_geography_coding"))stop("Invalid Workflow 06 pointer",call.=FALSE)
token<-Sys.getenv("ZENODO_ACCESS_TOKEN");if(!nzchar(token))stop("ZENODO_ACCESS_TOKEN is not set",call.=FALSE)
dir.create(output_dir,recursive=TRUE,showWarnings=FALSE)

files<-x$archive_files
if(is.data.frame(files))files<-lapply(seq_len(nrow(files)),function(i)as.list(files[i,,drop=FALSE]))
if(is.list(files)&&!is.null(files$filename))files<-list(files)
archives<-if(is.null(files)) list() else Filter(function(z)grepl("\\.tar\\.gz$",as.character(z$filename)),files)

# Legacy v1 pointers did not persist archive_files metadata. In that case,
# discover the published files from the authoritative Zenodo record itself.
if(length(archives)==0L){
  meta_url<-paste0("https://zenodo.org/api/records/",x$zenodo_record_id)
  meta_resp<-request(meta_url)|>
    req_headers(Authorization=paste("Bearer",token))|>
    req_timeout(60)|>
    req_error(is_error=function(resp)FALSE)|>
    req_perform()
  if(resp_status(meta_resp)!=200L)stop(sprintf("Zenodo record metadata HTTP %d",resp_status(meta_resp)),call.=FALSE)
  meta<-resp_body_json(meta_resp,simplifyVector=FALSE)
  zfiles<-meta$files
  if(is.data.frame(zfiles))zfiles<-lapply(seq_len(nrow(zfiles)),function(i)as.list(zfiles[i,,drop=FALSE]))
  if(is.list(zfiles)&&!is.null(zfiles$key))zfiles<-list(zfiles)
  candidates<-Filter(function(z){
    nm<-if(!is.null(z$key))z$key else if(!is.null(z$filename))z$filename else ""
    grepl("\\.tar\\.gz$",as.character(nm))
  },zfiles)
  if(length(candidates)!=1L)stop("Expected exactly one Workflow 06 archive tar.gz in Zenodo record",call.=FALSE)
  z<-candidates[[1L]]
  archives<-list(list(
    filename=if(!is.null(z$key))as.character(z$key) else as.character(z$filename),
    sha256=NULL
  ))
}
if(length(archives)!=1L)stop("Expected exactly one Workflow 06 archive tar.gz",call.=FALSE)
a<-archives[[1L]]
fn<-as.character(a$filename)
url<-paste0("https://zenodo.org/api/records/",x$zenodo_record_id,"/files/",URLencode(fn,reserved=TRUE),"/content")
dest<-file.path(output_dir,fn)
resp<-request(url)|>req_headers(Authorization=paste("Bearer",token))|>req_timeout(1800)|>req_error(is_error=function(resp)FALSE)|>req_perform()
if(resp_status(resp)!=200L)stop(sprintf("Zenodo download HTTP %d",resp_status(resp)),call.=FALSE)
writeBin(resp_body_raw(resp),dest)
if(!is.null(a$sha256)&&nzchar(as.character(a$sha256))){
  if(!identical(tolower(digest(file=dest,algo="sha256",serialize=FALSE)),tolower(as.character(a$sha256))))stop("Workflow 06 archive checksum mismatch",call.=FALSE)
}
utils::untar(dest,exdir=output_dir)
layer<-list.files(output_dir,pattern="^workflow06_geography_layer\\.csv$",recursive=TRUE,full.names=TRUE)
if(length(layer)!=1L)stop("Restored Workflow 06 archive lacks unique geography layer",call.=FALSE)
actual<-digest(file=layer[[1L]],algo="sha256",serialize=FALSE)
if(!identical(tolower(actual),tolower(as.character(x$workflow06_geography_layer_sha256))))stop("Restored Workflow 06 geography layer SHA mismatch",call.=FALSE)
cat(sprintf("PASS: restored Workflow 06 state from Zenodo record %s; records=%d\n",x$zenodo_record_id,as.integer(x$records)))
