#!/usr/bin/env Rscript
suppressPackageStartupMessages({library(httr2);library(jsonlite);library(digest)})

args<-commandArgs(trailingOnly=TRUE)
arg<-function(flag,default=NULL){i<-match(flag,args);if(is.na(i))return(default);if(i==length(args))stop(sprintf("Missing value after %s",flag),call.=FALSE);args[[i+1L]]}
pointer<-arg("--pointer");output_dir<-arg("--output-dir")
if(is.null(pointer)||is.null(output_dir))stop("Required: --pointer --output-dir",call.=FALSE)

x<-fromJSON(pointer,simplifyVector=FALSE)
if(!identical(x$status,"published")||!identical(x$workflow,"05")||!identical(x$state,"deterministic_species_coding"))stop("Invalid Workflow 05 pointer",call.=FALSE)
token<-Sys.getenv("ZENODO_ACCESS_TOKEN");if(!nzchar(token))stop("ZENODO_ACCESS_TOKEN is not set",call.=FALSE)
dir.create(output_dir,recursive=TRUE,showWarnings=FALSE)

files<-x$archive_files
if(is.data.frame(files))files<-lapply(seq_len(nrow(files)),function(i)as.list(files[i,,drop=FALSE]))
if(is.list(files)&&!is.null(files$filename))files<-list(files)
archives<-Filter(function(z)grepl("\\.tar\\.gz$",as.character(z$filename)),files)
if(length(archives)!=1L)stop("Expected exactly one Workflow 05 archive tar.gz",call.=FALSE)
a<-archives[[1L]]
fn<-as.character(a$filename)
url<-paste0("https://zenodo.org/api/records/",x$zenodo_record_id,"/files/",URLencode(fn,reserved=TRUE),"/content")
dest<-file.path(output_dir,fn)
resp<-request(url)|>req_headers(Authorization=paste("Bearer",token))|>req_timeout(1800)|>req_error(is_error=function(resp)FALSE)|>req_perform()
if(resp_status(resp)!=200L)stop(sprintf("Zenodo download HTTP %d",resp_status(resp)),call.=FALSE)
writeBin(resp_body_raw(resp),dest)
if(!identical(tolower(digest(file=dest,algo="sha256",serialize=FALSE)),tolower(as.character(a$sha256))))stop("Workflow 05 archive checksum mismatch",call.=FALSE)
utils::untar(dest,exdir=output_dir)

layer<-list.files(output_dir,pattern="^workflow05_species_layer\\.csv$",recursive=TRUE,full.names=TRUE)
matches<-list.files(output_dir,pattern="^species_matches\\.csv$",recursive=TRUE,full.names=TRUE)
if(length(layer)!=1L||length(matches)!=1L)stop("Restored Workflow 05 archive lacks unique species layer/matches files",call.=FALSE)

layer_sha<-digest(file=layer[[1L]],algo="sha256",serialize=FALSE)
matches_sha<-digest(file=matches[[1L]],algo="sha256",serialize=FALSE)
if(!identical(tolower(layer_sha),tolower(as.character(x$workflow05_species_layer_sha256))))stop("Restored Workflow 05 species layer SHA mismatch",call.=FALSE)
if(!identical(tolower(matches_sha),tolower(as.character(x$species_matches_sha256))))stop("Restored Workflow 05 species matches SHA mismatch",call.=FALSE)

cat(sprintf("PASS: restored Workflow 05 state from Zenodo record %s; records=%d\n",x$zenodo_record_id,as.integer(x$records)))
