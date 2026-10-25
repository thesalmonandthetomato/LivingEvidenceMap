#!/usr/bin/env Rscript
# Restore a previously validated restricted W08b review export.
suppressPackageStartupMessages({library(httr2);library(jsonlite)})
args<-commandArgs(TRUE)
if(length(args)!=3L)stop("Expected deposition ID, expected queue SHA, destination")
id<-args[[1]];expected<-args[[2]];out<-args[[3]]
if(!grepl("^[0-9]+$",id)||!grepl("^[0-9a-f]{64}$",expected))stop("Invalid export identifier")
token<-Sys.getenv("ZENODO_ACCESS_TOKEN","")
if(!nzchar(token))stop("Zenodo token missing")
auth<-function(q)req_auth_bearer_token(q,token)
p<-request(paste0("https://zenodo.org/api/deposit/depositions/",id))|>
 auth()|>req_perform()|>resp_body_json(simplifyVector=FALSE)
if(!isTRUE(p$submitted))stop("Review export not published")
bucket<-as.character(p$links$bucket)
if(!nzchar(bucket))stop("Review export has no bucket")
dir.create(out,recursive=TRUE,showWarnings=FALSE)
target<-file.path(out,"review.zip")
response<-request(paste0(sub("/$","",bucket),"/w08b-human-decisions.zip"))|>
  auth()|>req_timeout(900)|>req_error(is_error=function(r)FALSE)|>req_perform(path=target)
if(resp_status(response)!=200L)stop("Cannot retrieve published W08b review archive")
unzip(target,exdir=out)
manifest<-fromJSON(file.path(out,"manifest.json"))
if(!identical(as.character(manifest$queue_sha256),expected)||manifest$decision_count!=manifest$cases)
 stop("Review archive integrity mismatch")
for(p in c("queue.csv","decisions.csv","abstract_repairs.csv"))if(!file.exists(file.path(out,p)))stop("Review archive missing ",p)
cat("PASS: W08b archived review restored and linked to queue SHA\n")
