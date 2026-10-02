#!/usr/bin/env Rscript
suppressPackageStartupMessages({library(httr2);library(jsonlite);library(digest)})

args<-commandArgs(trailingOnly=TRUE)
arg<-function(flag,default=NULL){i<-match(flag,args);if(is.na(i))return(default);if(i==length(args))stop(sprintf("Missing value after %s",flag),call.=FALSE);args[[i+1L]]}
record_id<-arg("--zenodo-record-id"); out<-arg("--output-dir")
if(is.null(record_id)||is.null(out))stop("Required: --zenodo-record-id --output-dir",call.=FALSE)
token<-Sys.getenv("ZENODO_ACCESS_TOKEN");if(!nzchar(token))stop("ZENODO_ACCESS_TOKEN required",call.=FALSE)
dir.create(out,recursive=TRUE,showWarnings=FALSE)
`%||%`<-function(x,y)if(is.null(x))y else x

auth<-function(req) req|>req_headers(Authorization=paste("Bearer",token))
api<-paste0("https://zenodo.org/api/deposit/depositions/",record_id)
dep<-request(api)|>auth()|>req_timeout(120)|>req_error(is_error=function(resp)FALSE)|>req_perform()
if(resp_status(dep)!=200L)stop(sprintf("Zenodo deposition lookup HTTP %d",resp_status(dep)),call.=FALSE)
d<-resp_body_json(dep,simplifyVector=FALSE)
if(!isTRUE(d$submitted))stop("Manual repair Zenodo record is not published",call.=FALSE)
access<-as.character((d$metadata%||%list())$access_right%||%"")
if(!identical(access,"restricted"))stop(sprintf("Manual repair record must be restricted; got %s",access),call.=FALSE)
bucket<-as.character(d$links$bucket)

required<-c("manifest.json","repair_overlay.jsonl","force_rescreen_record_ids.txt")
for(fn in required){
  dest<-file.path(out,fn)
  resp<-request(paste0(sub("/$","",bucket),"/",URLencode(fn,reserved=TRUE)))|>req_method("GET")|>auth()|>req_timeout(600)|>req_error(is_error=function(resp)FALSE)|>req_perform(path=dest)
  if(resp_status(resp)!=200L)stop(sprintf("Zenodo download failed for %s HTTP %d",fn,resp_status(resp)),call.=FALSE)
}
m<-fromJSON(file.path(out,"manifest.json"),simplifyVector=FALSE)
if(!identical(as.character(m$schema),"living-evidence-map-manual-metadata-repair-v1"))stop("Unexpected manual repair manifest schema",call.=FALSE)
overlay_sha<-digest(file=file.path(out,"repair_overlay.jsonl"),algo="sha256",serialize=FALSE)
force_sha<-digest(file=file.path(out,"force_rescreen_record_ids.txt"),algo="sha256",serialize=FALSE)
if(!identical(tolower(overlay_sha),tolower(as.character(m$overlay_sha256))))stop("Repair overlay SHA mismatch",call.=FALSE)
if(!identical(tolower(force_sha),tolower(as.character(m$force_rescreen_ids_sha256))))stop("Force-rescreen ID SHA mismatch",call.=FALSE)
cat(sprintf("PASS: restored restricted W04 manual repair bundle %s; records=%d title=%d abstract=%d\n",
            record_id,as.integer(m$records_with_repairs),as.integer(m$title_repairs),as.integer(m$abstract_repairs)))
