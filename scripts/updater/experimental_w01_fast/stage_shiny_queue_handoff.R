#!/usr/bin/env Rscript
# Read-only conversion of an isolated Fast pending review checkpoint into
# the existing W01 Shiny queue payload. Never writes to Google Sheets.
suppressPackageStartupMessages({library(jsonlite);library(digest)})
a<-commandArgs(trailingOnly=TRUE)
arg<-function(k){i<-match(k,a);if(is.na(i)||i==length(a))stop("Missing ",k);a[[i+1L]]}
fast<-arg("--fast-root");out<-arg("--output-dir");run_id<-arg("--source-run-id")
if(dir.exists(out)||file.exists(out))stop("Refuse overwrite")
queue<-file.path(fast,"adjudication","human_review_package","human_review_cases.jsonl")
manifest_path<-file.path(fast,"adjudication","human_review_package","review_manifest.json")
report_path<-file.path(fast,"run_report.json")
if(any(!file.exists(c(queue,manifest_path,report_path))))stop("Fast pending checkpoint incomplete")
report<-fromJSON(report_path,simplifyVector=FALSE)
if(!identical(report$status,"AWAITING_HUMAN_REVIEW"))stop("Not a pending Fast review checkpoint")
qm<-fromJSON(manifest_path,simplifyVector=FALSE)
if(!identical(qm$schema,"living-evidence-map-workflow01-human-review-manifest-v1"))stop("Invalid review manifest schema")
lines<-readLines(queue,warn=FALSE,encoding="UTF-8")
lines<-lines[nzchar(trimws(lines))]
if(!length(lines)||as.integer(qm$pending_count)!=length(lines))stop("Queue count mismatch")
sha<-digest(file=queue,algo="sha256",serialize=FALSE)
if(!identical(qm$queue_sha256,sha))stop("Review queue SHA mismatch")
objs<-lapply(lines,fromJSON,simplifyVector=FALSE)
ids<-vapply(objs,function(z)as.character(z$review_case_id),character(1))
schemas<-vapply(objs,function(z)as.character(z$schema),character(1))
if(anyDuplicated(ids)||any(!nzchar(ids))||
 any(schemas!="living-evidence-map-workflow01-duplicate-adjudication-case-v1"))
 stop("Invalid or duplicate Shiny review case")
if(!grepl("^[0-9]+$",run_id))stop("Source run ID must be a GitHub numeric run ID")
dir.create(out,recursive=TRUE)
writeLines(lines,file.path(out,"human_review_cases.jsonl"),useBytes=TRUE)
file.copy(manifest_path,file.path(out,"review_manifest.json"))
payload<-data.frame(batch_id=paste0("w01-run-",run_id),
 queue_sha256=sha,case_index=as.character(seq_along(ids)),
 review_case_id=ids,case_json=lines,stringsAsFactors=FALSE)
utils::write.csv(payload,file.path(out,"shiny_queue_payload.csv"),row.names=FALSE,na="")
write_json(list(schema="w01-fast-shiny-queue-handoff-v1",status="STAGED_NOT_PUBLISHED",
 source_run_id=run_id,queue_sha256=sha,pending_cases=length(ids),
 payload_sha256=digest(file=file.path(out,"shiny_queue_payload.csv"),algo="sha256"),
 publication_allowed=FALSE,workflow02_dispatch_allowed=FALSE),
 file.path(out,"handoff_manifest.json"),auto_unbox=TRUE,pretty=TRUE)
cat(sprintf("PASS: staged %d authentic W01 Shiny cases, no external writes\\n",length(ids)))
