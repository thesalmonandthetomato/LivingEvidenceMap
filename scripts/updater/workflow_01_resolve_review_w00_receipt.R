#!/usr/bin/env Rscript
# Resolve a review's published W00 handoff receipt; read-only against Google Sheets.
suppressPackageStartupMessages({library(jsonlite);library(googlesheets4)})
args<-commandArgs(trailingOnly=TRUE)
get<-function(k){i<-match(k,args);if(is.na(i)||i==length(args))stop("Missing ",k,call.=FALSE);args[[i+1L]]}
sheet<-get("--sheet-id");credential<-get("--credential")
review<-get("--review-id");output<-get("--output")
if(!grepl("^[A-Za-z0-9][A-Za-z0-9._-]{3,127}$",review))stop("Invalid review ID",call.=FALSE)
if(!file.exists(credential))stop("Missing service account",call.=FALSE)
gs4_auth(path=credential,cache=FALSE)
m<-as.data.frame(read_sheet(sheet,sheet="review_metadata",col_types="cc"))
e<-as.data.frame(read_sheet(sheet,sheet="workflow_events",col_types="cccccccc"))
if(!identical(names(m),c("key","value"))||
 !identical(names(e),c("event_id","timestamp_utc","review_id","workflow","event_type","github_run_id","zenodo_record_id","details_json")))
 stop("Unexpected review Sheets schema",call.=FALSE)
if(anyDuplicated(m$key))stop("Duplicate metadata keys",call.=FALSE)
v<-function(k){i<-match(k,m$key);if(is.na(i))stop("Missing ",k,call.=FALSE);as.character(m$value[[i]])}
if(!identical(v("review_id"),review)||!identical(v("latest_w00_status"),"success"))stop("Review mismatch or W00 not successful",call.=FALSE)
run<-v("latest_w00_run_id");record<-v("latest_w00_zenodo_record_id")
if(!grepl("^[0-9]+$",run)||!grepl("^[0-9]+$",record))stop("Invalid W00 run or record",call.=FALSE)
id<-paste0("W00:",run,":zenodo_published")
rows<-which(e$event_id==id & e$review_id==review & e$workflow=="W00" & e$event_type=="zenodo_published")
if(length(rows)!=1L)stop("Missing or ambiguous published W00 event",call.=FALSE)
entry<-e[rows,,drop=FALSE]
if(!identical(as.character(entry$github_run_id[[1L]]),run)||
   !identical(as.character(entry$zenodo_record_id[[1L]]),record))stop("Event/metadata disagreement",call.=FALSE)
details<-fromJSON(as.character(entry$details_json[[1L]]),simplifyVector=FALSE)
receipt<-details$receipt
if(is.null(receipt))stop("W00 event lacks complete receipt; cannot restore safely",call.=FALSE)
if(!identical(receipt$status,"published")||!identical(receipt$visibility,"restricted")||
  !identical(as.character(receipt$review_id),review)||
  !identical(as.character(receipt$github_run_id),run)||
  !identical(as.character(receipt$zenodo_record_id),record))
 stop("Review-specific W00 receipt mismatch",call.=FALSE)
if(is.null(receipt$zenodo_deposition_id)||!grepl("^[0-9]+$",as.character(receipt$zenodo_deposition_id))||
 is.null(receipt$archive_files)||!length(receipt$archive_files)||is.null(receipt$sources)||!length(receipt$sources))
 stop("W00 receipt missing archive restore fields",call.=FALSE)
dir.create(dirname(output),recursive=TRUE,showWarnings=FALSE)
write_json(receipt,output,auto_unbox=TRUE,pretty=TRUE,null="null")
cat("PASS: wrote validated review-specific W00 pointer to ",output,"\n",sep="")
