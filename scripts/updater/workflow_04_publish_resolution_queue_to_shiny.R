#!/usr/bin/env Rscript
suppressPackageStartupMessages({library(googlesheets4);library(jsonlite);library(digest)})
args<-commandArgs(trailingOnly=TRUE)
arg<-function(flag,default=NULL){i<-match(flag,args);if(is.na(i))return(default);if(i==length(args))stop(sprintf("Missing value after %s",flag),call.=FALSE);args[[i+1L]]}
queue_path<-arg("--queue");manifest_path<-arg("--manifest");highlight_path<-arg("--highlight-terms")
sheet_id<-arg("--sheet-id",Sys.getenv("LEM_GOOGLE_SHEET_ID"));credential<-arg("--credential",Sys.getenv("LEM_GOOGLE_SERVICE_ACCOUNT_JSON"))
tab<-arg("--queue-tab","queue_w04_validation_active");receipt_path<-arg("--receipt","")
if(any(vapply(list(queue_path,manifest_path,highlight_path,sheet_id,credential),is.null,logical(1))))stop("Required W04 resolution publisher argument missing",call.=FALSE)
if(!file.exists(credential))stop("Google credential file missing",call.=FALSE)

lines<-readLines(queue_path,warn=FALSE,encoding="UTF-8");lines<-lines[nzchar(trimws(lines))]
if(!length(lines))stop("W04 resolution queue is empty",call.=FALSE)
m<-fromJSON(manifest_path,simplifyVector=FALSE)
if(!identical(as.character(m$schema),"living-evidence-map-workflow04-resolution-queue-v1")||!identical(as.character(m$status),"PASS"))stop("Invalid W04 resolution manifest",call.=FALSE)
sha<-digest(file=queue_path,algo="sha256",serialize=FALSE)
if(!identical(tolower(sha),tolower(as.character(m$queue_sha256))))stop("W04 resolution queue SHA mismatch",call.=FALSE)
cases<-lapply(lines,fromJSON,simplifyVector=FALSE)
ids<-vapply(cases,function(z)as.character(z$review_case_id),character(1))
if(any(!nzchar(ids))||anyDuplicated(ids))stop("W04 resolution case ID invariant failed",call.=FALSE)
source_run_id<-as.character(m$source_run_id)
if(!grepl("^[0-9]+$",source_run_id))stop("Invalid W04 resolution source_run_id",call.=FALSE)
batch_id<-paste0("w04-resolution-",source_run_id,"-",substr(sha,1,12))

highlight<-read.csv(highlight_path,stringsAsFactors=FALSE,na.strings="")
include_terms<-if("words_for_include"%in%names(highlight))unique(trimws(highlight$words_for_include[!is.na(highlight$words_for_include)&nzchar(trimws(highlight$words_for_include))]))else character()
exclude_terms<-if("words_for_exclude"%in%names(highlight))unique(trimws(highlight$words_for_exclude[!is.na(highlight$words_for_exclude)&nzchar(trimws(highlight$words_for_exclude))]))else character()
include_json<-toJSON(include_terms,auto_unbox=FALSE);exclude_json<-toJSON(exclude_terms,auto_unbox=FALSE)

payload<-data.frame(
  batch_id=rep(batch_id,length(lines)),
  queue_sha256=rep(sha,length(lines)),
  case_index=as.character(seq_along(lines)),
  review_case_id=ids,
  case_json=lines,
  review_mode=c("resolution",rep("",max(0,length(lines)-1L))),
  source_run_id=c(source_run_id,rep("",max(0,length(lines)-1L))),
  highlight_include_json=c(include_json,rep("",max(0,length(lines)-1L))),
  highlight_exclude_json=c(exclude_json,rep("",max(0,length(lines)-1L))),
  stringsAsFactors=FALSE
)

gs4_auth(path=credential,cache=FALSE)
tabs<-sheet_names(sheet_id);if(!tab%in%tabs)sheet_add(sheet_id,sheet=tab)
sheet_write(payload,ss=sheet_id,sheet=tab)
verify<-read_sheet(sheet_id,sheet=tab,col_types="c")
req<-names(payload)
if(!all(req%in%names(verify))||nrow(verify)!=length(lines))stop("Published W04 resolution queue shape mismatch",call.=FALSE)
verify<-verify[,req,drop=FALSE]
if(!identical(as.character(verify$review_case_id),ids))stop("Published W04 resolution case order mismatch",call.=FALSE)
reconstructed<-paste0(paste(verify$case_json,collapse="\n"),"\n")
if(!identical(digest(reconstructed,algo="sha256",serialize=FALSE),sha))stop("Published W04 resolution queue reconstruction SHA mismatch",call.=FALSE)
if(nzchar(receipt_path)){
  dir.create(dirname(receipt_path),recursive=TRUE,showWarnings=FALSE)
  writeLines(toJSON(list(schema="living-evidence-map-workflow04-resolution-publish-v1",status="PASS",
    source_run_id=source_run_id,batch_id=batch_id,queue_sha256=sha,records=length(lines),
    queue_tab=tab,published_at_utc=format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ")),
    auto_unbox=TRUE,pretty=TRUE),receipt_path,useBytes=TRUE)
}
cat(sprintf("PASS: published W04 resolution queue: records=%d batch=%s sha=%s\n",length(lines),batch_id,sha))
cat(sprintf("BATCH_ID=%s\nQUEUE_SHA256=%s\n",batch_id,sha))
