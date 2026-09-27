#!/usr/bin/env Rscript
suppressPackageStartupMessages({
  library(jsonlite)
  library(digest)
})

args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag,default=NULL) {
  i <- match(flag,args)
  if(is.na(i)) return(default)
  if(i==length(args)) stop(sprintf("Missing value after %s",flag),call.=FALSE)
  args[[i+1L]]
}
queue_path <- arg("--queue")
manifest_path <- arg("--manifest")
output_dir <- arg("--output-dir")
intake_run_id <- arg("--intake-run-id")
notification_run_id <- arg("--notification-run-id",Sys.getenv("GITHUB_RUN_ID",""))
repository <- arg("--repository",Sys.getenv("GITHUB_REPOSITORY","thesalmonandthetomato/LivingEvidenceMap"))
branch <- arg("--branch","workflow01-final-architecture")
if(any(vapply(list(queue_path,manifest_path,output_dir,intake_run_id),is.null,logical(1)))) {
  stop("Required: --queue --manifest --output-dir --intake-run-id",call.=FALSE)
}
if(!file.exists(queue_path)||!file.exists(manifest_path)) stop("Queue or manifest missing",call.=FALSE)
dir.create(output_dir,recursive=TRUE,showWarnings=FALSE)

m <- fromJSON(manifest_path,simplifyVector=FALSE)
sha <- digest(file=queue_path,algo="sha256",serialize=FALSE)
if(!identical(as.character(m$queue_sha256),sha)) stop("Queue SHA does not match locked intake manifest")

lines <- readLines(queue_path,warn=FALSE,encoding="UTF-8")
lines <- lines[nzchar(trimws(lines))]
cases <- lapply(lines,fromJSON,simplifyVector=FALSE)
ids <- vapply(cases,function(x)as.character(x$record_id),character(1))
if(anyDuplicated(ids)) stop("Review queue contains duplicate record_id")
issue_n <- sum(vapply(cases,function(x)length(x$issues),integer(1)))
if(length(cases)!=as.integer(m$unique_records_pending_human_review)) stop("Queue record count mismatch")
if(issue_n!=as.integer(m$total_pending_issues)) stop("Queue issue count mismatch")

locked_queue <- file.path(output_dir,"workflow08_review_queue.jsonl")
writeLines(lines,locked_queue,useBytes=TRUE)

decision_dir <- sprintf("data/adjudication/workflow08/run-%s",intake_run_id)
decision_path <- sprintf("%s/human_decisions.jsonl",decision_dir)
complete_path <- sprintf("%s/COMPLETE.json",decision_dir)

review_manifest <- list(
  schema="living-evidence-map-workflow08-human-review-manifest-v1",
  repository=repository,
  branch=branch,
  intake_run_id=intake_run_id,
  notification_run_id=notification_run_id,
  status="awaiting_human_review",
  pending_records=length(cases),
  pending_issues=issue_n,
  queue_sha256=sha,
  decisions_path=decision_path,
  complete_marker_path=complete_path
)
write_json(review_manifest,file.path(output_dir,"review_manifest.json"),
           pretty=TRUE,auto_unbox=TRUE,null="null")

handoff <- c(
  "# LivingEvidenceMap Workflow 08 human adjudication",
  "",
  "Use this prompt in a new ChatGPT chat to continue the LivingEvidenceMap human-adjudication stage.",
  "",
  sprintf("Repository: %s",repository),
  sprintf("Branch: %s",branch),
  sprintf("Locked W08 intake run: %s",intake_run_id),
  sprintf("Pending unique records: %d",length(cases)),
  sprintf("Pending review issues: %d",issue_n),
  sprintf("Locked queue SHA-256: %s",sha),
  "",
  "## Task",
  "",
  "Retrieve the Workflow 08 review artefact from the supplied GitHub Actions run and read workflow08_review_queue.jsonl. Treat that queue and its SHA-256 as immutable. Do not regenerate or expand it.",
  "",
  "Review records one at a time. For each record:",
  "",
  "1. Show the title and abstract.",
  "2. Show every issues[] entry for that record, including the automated value and why it entered W08.",
  "3. Explain the evidence briefly and neutrally.",
  "4. Ask Neal for the human decision. Do not silently decide on his behalf.",
  "5. When Neal decides, write one immutable JSONL decision line for each resolved issue.",
  "",
  "A single record can contain multiple issues. Resolve each issue separately, but present the record only once.",
  "",
  "## Decision schema",
  "",
  "Each human decision JSON object must contain:",
  "",
  "- review_key: <record_id>::<issue_type>",
  "- record_id",
  "- issue_type",
  "- decision",
  "- final_value",
  "- rationale",
  "- reviewer: Neal Haddaway",
  "- resolved_at_utc",
  sprintf("- queue_sha256: %s",sha),
  "",
  "Allowed decisions and final_value formats:",
  "",
  "### species_none",
  "- assign_named_species -> final_value = {species_labels:[one or more of Atlantic salmon, Rainbow trout, Chinook salmon, Coho salmon, Sockeye salmon, Chum salmon, Pink salmon, Masu salmon]}",
  "- assign_unspecified_species -> final_value = {species_labels:[Unspecified species]}",
  "- exclude_record -> final_value = {included:false}",
  "",
  "### geography_unresolved",
  "- assign_country_set -> final_value = {geography_status:RESOLVED, iso3c:[...], country_names:[...]}",
  "- assign_none -> final_value = {geography_status:NONE, iso3c:[], country_names:[]}",
  "",
  "### geography_evidence_unvalidated",
  "- accept_model -> final_value reproduces the accepted automated geography status/country set",
  "- override_country_set -> final_value = {geography_status:RESOLVED, iso3c:[...], country_names:[...]}",
  "- assign_none -> final_value = {geography_status:NONE, iso3c:[], country_names:[]}",
  "",
  "### topic_extreme_disagreement",
  "- accept_retained_topics -> final_value = {path_ids:[the currently retained path IDs]}",
  "- replace_topic_set -> final_value = {path_ids:[valid v3.6 ontology path IDs]}",
  "- exclude_record -> final_value = {included:false}",
  "",
  "### zero_topic_eligibility_uncertain",
  "- include_uncoded -> final_value = {included:true, topic_status:included_uncoded}",
  "- exclude_record -> final_value = {included:false}",
  "",
  "If Neal identifies a relevance problem while adjudicating any issue, exclusion is permitted only where the issue's allowed_human_outcomes includes exclude_record. If a new problem falls outside the locked queue schema, record it separately for later methodological review rather than silently changing the queue.",
  "",
  "## Writing decisions back",
  "",
  sprintf("Write decisions to: %s",decision_path),
  "",
  "Preserve earlier decisions when adding new ones. review_key must be unique. Never overwrite a different prior decision silently; if Neal changes a decision, update that line explicitly and preserve the rationale for the change.",
  "",
  "The queue is complete only when every issues[] entry has exactly one non-pending human decision.",
  "",
  sprintf("When all %d issues are resolved, create: %s",issue_n,complete_path),
  "",
  "The COMPLETE marker must contain the resolved issue count, unique record count, queue SHA-256 and SHA-256 of human_decisions.jsonl. Only then should the final W08 assembly/Zenodo workflow be run.",
  "",
  "Existing geography decisions already recorded before this locked queue are not to be re-reviewed unless Neal explicitly asks to revisit them."
)
writeLines(handoff,file.path(output_dir,"CHATGPT_HANDOFF.md"))

idx <- vapply(cases,function(x) {
  types <- vapply(x$issues,function(q)as.character(q$issue_type),character(1))
  sprintf("- %s | %s | %s",x$record_id,paste(types,collapse=" + "),as.character(x$title))
},character(1))
writeLines(c("# Workflow 08 pending record index","",idx),file.path(output_dir,"case_index.md"))

cat(sprintf("PASS: W08 review package built for %d records / %d issues\n",length(cases),issue_n))
