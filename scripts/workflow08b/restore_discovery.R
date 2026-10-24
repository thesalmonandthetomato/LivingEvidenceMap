#!/usr/bin/env Rscript
# Restore restricted W08b Zenodo checkpoint, verify SHA-256, derive a private
# retry input from its own seed ledger. No W01 reconstruction needed.
suppressPackageStartupMessages({library(jsonlite);library(httr2);library(digest)})
a<-commandArgs(trailingOnly=TRUE)
if(length(a)!=3L)stop("Usage: restore_discovery.R <zenodo-record-id> <expected-sha256> <output-dir>")
record<-a[[1]];expected<-tolower(a[[2]]);out<-a[[3]]
if(!grepl("^[0-9]+$",record)||!grepl("^[a-f0-9]{64}$",expected))stop("Invalid immutable checkpoint reference")
if(dir.exists(out)&&length(list.files(out,all.files=TRUE,no..=TRUE)))stop("Refusing to overwrite checkpoint directory")
dir.create(out,recursive=TRUE,showWarnings=FALSE)
token<-Sys.getenv("ZENODO_ACCESS_TOKEN","");if(!nzchar(token))stop("Missing ZENODO_ACCESS_TOKEN")
api<-paste0("https://zenodo.org/api/deposit/depositions/",record)
response<-request(api)|>req_headers(Authorization=paste("Bearer",token))|>req_timeout(90)|>req_perform()
dep<-resp_body_json(response,simplifyVector=FALSE)
if(!isTRUE(dep$submitted))stop("Checkpoint has not been published")
files<-Filter(function(x)grepl("^w08b-discovery-run-.*[.]tar[.]gz$",as.character(x$filename)),dep$files)
if(length(files)!=1L)stop("Expected one W08b checkpoint tarball")
fn<-as.character(files[[1]]$filename)
archive<-tempfile(fileext=".tar.gz")
url<-paste0(sub("/$","",as.character(dep$links$bucket)),"/",URLencode(fn,reserved=TRUE))
res<-request(url)|>req_headers(Authorization=paste("Bearer",token))|>req_timeout(1800)|>
 req_error(is_error=function(x)FALSE)|>req_perform(path=archive)
if(resp_status(res)!=200L)stop("Checkpoint download HTTP ",resp_status(res))
actual<-tolower(digest(file=archive,algo="sha256",serialize=FALSE))
if(!identical(actual,expected))stop("W08b checkpoint checksum mismatch")
members<-utils::untar(archive,list=TRUE)
if(!length(members)||any(grepl("^/|(^|/)\\.\\.(/|$)",members)))stop("Unsafe archive member paths")
utils::untar(archive,exdir=out)
ledger<-file.path(out,"lens_seed_status.jsonl")
if(!file.exists(ledger))stop("Missing seed journal")
entries<-lapply(readLines(ledger,warn=FALSE),function(z)fromJSON(z,simplifyVector=FALSE))
current<-list()
for(x in entries)current[[as.character(x$record_id)]]<-x
if(length(current)!=10L)stop("Expected precisely ten checkpoint seeds")
rows<-lapply(current,function(x)data.frame(record_id=x$record_id,
 lens_id=x$lens_id,doi="",preferred_route="lens",
 identifier_conflict=FALSE,stringsAsFactors=FALSE))
d<-do.call(rbind,rows);d<-d[order(d$record_id),,drop=FALSE]
write.csv(d,file.path(out,"checkpoint_seed_crosswalk.csv"),row.names=FALSE,quote=TRUE)
cat("PASS: recovered verified Zenodo checkpoint ",record,"; completed=",
 sum(vapply(current,function(x)identical(x$status,"complete"),logical(1))),
 "; incomplete=",sum(vapply(current,function(x)!identical(x$status,"complete"),logical(1))),"\n",sep="")
