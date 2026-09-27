#!/usr/bin/env Rscript
suppressPackageStartupMessages(library(jsonlite))
args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag,default=NULL){
  i<-match(flag,args)
  if(is.na(i)) return(default)
  if(i==length(args)) stop(sprintf("Missing value after %s",flag),call.=FALSE)
  args[[i+1L]]
}
manifest_path<-arg("--manifest")
artifact_url<-arg("--artifact-url")
workflow_url<-arg("--workflow-url")
output_path<-arg("--output")
if(any(vapply(list(manifest_path,artifact_url,workflow_url,output_path),is.null,logical(1)))) {
  stop("Required: --manifest --artifact-url --workflow-url --output",call.=FALSE)
}
m<-fromJSON(manifest_path,simplifyVector=FALSE)
recipient<-Sys.getenv("REVIEW_EMAIL","")
if(!nzchar(recipient)) recipient<-Sys.getenv("SMTP_USERNAME","")
if(!nzchar(recipient)) stop("REVIEW_EMAIL or SMTP_USERNAME must be set")
body<-paste(
  "LivingEvidenceMap Workflow 08 is ready for human adjudication.",
  "",
  sprintf("Pending unique records: %d",as.integer(m$pending_records)),
  sprintf("Pending review issues: %d",as.integer(m$pending_issues)),
  sprintf("Locked queue SHA-256: %s",m$queue_sha256),
  "",
  "Download the human-review package:",
  artifact_url,
  "",
  "The package contains CHATGPT_HANDOFF.md and the immutable workflow08_review_queue.jsonl.",
  "",
  "Start a new ChatGPT chat, paste CHATGPT_HANDOFF.md, and provide this workflow link so ChatGPT can retrieve the review artefact through GitHub:",
  workflow_url,
  "",
  "Human decisions will be written back to GitHub as a Workflow 08 adjudication JSONL. The final canonical JSONL will not be assembled or archived until every mandatory issue is resolved.",
  sep="\n"
)
payload<-list(
  recipient=recipient,
  subject=sprintf("LivingEvidenceMap: Workflow 08 review ready — %d records",as.integer(m$pending_records)),
  pending_count=as.integer(m$pending_records),
  pending_issues=as.integer(m$pending_issues),
  body_text=body
)
write_json(payload,output_path,pretty=TRUE,auto_unbox=TRUE,null="null")
cat("PASS: W08 email payload built\n")
