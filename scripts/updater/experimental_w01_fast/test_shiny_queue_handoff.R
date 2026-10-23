#!/usr/bin/env Rscript
suppressPackageStartupMessages({library(jsonlite);library(digest)})
root<-tempfile("w01-fast-shiny-queue-");dir.create(root)
on.exit(unlink(root,recursive=TRUE,force=TRUE),add=TRUE)
at<-function(...)file.path(root,...)
dir.create(at("fast","adjudication","human_review_package"),recursive=TRUE)
pkg<-at("fast","adjudication","human_review_package")
q<-file.path(pkg,"human_review_cases.jsonl")
case<-list(schema="living-evidence-map-workflow01-duplicate-adjudication-case-v1",
 review_case_id="hr-fixture",record_i=list(source="a",source_record_id="1"),
 record_j=list(source="b",source_record_id="2"))
writeLines(toJSON(case,auto_unbox=TRUE),q)
sha<-digest(file=q,algo="sha256")
write_json(list(schema="living-evidence-map-workflow01-human-review-manifest-v1",
 pending_count=1L,queue_sha256=sha),file.path(pkg,"review_manifest.json"),auto_unbox=TRUE)
write_json(list(status="AWAITING_HUMAN_REVIEW"),at("fast","run_report.json"),auto_unbox=TRUE)
call<-function(out)system2(file.path(R.home("bin"),"Rscript"),
 c("scripts/updater/experimental_w01_fast/stage_shiny_queue_handoff.R",
 "--fast-root",at("fast"),"--output-dir",out,"--source-run-id","12345"),
 stdout=TRUE,stderr=TRUE)
x<-suppressWarnings(call(at("valid")))
if(!is.null(attr(x,"status"))&&attr(x,"status")!=0L)stop(paste(x,collapse=" | "))
m<-fromJSON(at("valid","handoff_manifest.json"))
payload<-read.csv(at("valid","shiny_queue_payload.csv"),colClasses="character")
stopifnot(m$status=="STAGED_NOT_PUBLISHED",m$pending_cases==1L,
 identical(m$queue_sha256,sha),identical(payload$review_case_id,"hr-fixture"),
 identical(payload$case_json,readLines(q)),identical(m$publication_allowed,FALSE),
 identical(m$workflow02_dispatch_allowed,FALSE))
write_json(list(status="PASS_SHADOW_NO_PUBLICATION"),at("fast","run_report.json"),auto_unbox=TRUE)
bad<-suppressWarnings(call(at("not_pending")))
stopifnot(!is.null(attr(bad,"status")),attr(bad,"status")!=0L,
 !file.exists(at("not_pending")))
cat("PASS: authentic Shiny queue payload, SHA and fail-closed pending status without external writes\n")
