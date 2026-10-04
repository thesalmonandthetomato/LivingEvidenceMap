#!/usr/bin/env Rscript
suppressPackageStartupMessages({library(jsonlite);library(digest)})
args<-commandArgs(trailingOnly=TRUE)
arg<-function(flag){i<-match(flag,args);if(is.na(i)||i==length(args))stop("Missing ",flag,call.=FALSE);args[[i+1L]]}
queue_path<-arg("--queue")
reused_path<-arg("--reused")
out_dir<-arg("--output-dir")
dir.create(out_dir,recursive=TRUE,showWarnings=FALSE)

`%||%`<-function(x,y)if(is.null(x)||length(x)==0L)y else x
clean<-function(x){if(is.null(x)||!length(x))return("");z<-as.character(x[[1L]]);if(is.na(z))"" else z}
canon_hash<-function(x)digest(toJSON(x,auto_unbox=TRUE,null="null",na="null",digits=NA,pretty=FALSE),algo="sha256",serialize=FALSE)
read_jsonl<-function(path){x<-readLines(path,warn=FALSE,encoding="UTF-8");x<-x[nzchar(trimws(x))];lapply(x,fromJSON,simplifyVector=FALSE)}
write_jsonl<-function(rows,path){con<-file(path,"wt",encoding="UTF-8");on.exit(close(con),add=TRUE);for(z in rows)writeLines(toJSON(z,auto_unbox=TRUE,null="null",na="null",digits=NA),con,useBytes=TRUE)}

# Starting from the exact successful pre-exclude queue, change only the
# geography decision vocabularies by appending exclude_record and recompute
# their issue-state hashes.
queue<-read_jsonl(queue_path)
geo_changed<-0L
for(i in seq_along(queue)){
  rec<-queue[[i]]
  rid<-clean(rec$record_id)
  for(j in seq_along(rec$issues%||%list())){
    issue<-rec$issues[[j]]
    typ<-clean(issue$issue_type)
    if(!typ%in%c("geography_unresolved","geography_evidence_unvalidated","geography_model_failure"))next

    expected_old<-switch(
      typ,
      geography_unresolved=c("accept_model","override_country_set","assign_none"),
      geography_evidence_unvalidated=c("accept_model","override_country_set","assign_none"),
      geography_model_failure=c("assign_country_set","assign_none")
    )
    expected_new<-c(expected_old,"exclude_record")
    if(!identical(as.character(issue$allowed_human_outcomes),expected_old)){
      stop("Unexpected pre-change geography vocabulary for ",rid," / ",typ,call.=FALSE)
    }
    issue$allowed_human_outcomes<-expected_new
    state<-list(
      review_key=paste(rid,typ,sep="::"),
      record_id=rid,
      issue_type=typ,
      source_workflow=clean(issue$source_workflow),
      title=clean(rec$title),
      abstract=clean(rec$abstract),
      automated_value=issue$automated_value,
      allowed_human_outcomes=issue$allowed_human_outcomes
    )
    issue$issue_state_sha256<-canon_hash(state)
    rec$issues[[j]]<-issue
    geo_changed<-geo_changed+1L
  }
  queue[[i]]<-rec
}
if(geo_changed!=119L)stop("Expected 119 geography issues in source queue, got ",geo_changed,call.=FALSE)

new_queue<-file.path(out_dir,"current_queue_with_geo_exclude.jsonl")
write_jsonl(queue,new_queue)

# Real decisions reused by the successful source run are the historical ledger.
prior<-read_jsonl(reused_path)
prior_path<-file.path(out_dir,"prior_real_reused_decisions.jsonl")
write_jsonl(prior,prior_path)

prod_out<-file.path(out_dir,"production_reuse")
dir.create(prod_out,recursive=TRUE,showWarnings=FALSE)
status<-system2("Rscript",c(
  "scripts/updater/workflow_08_reuse_decisions.R",
  "--queue",new_queue,
  "--prior-ledger",prior_path,
  "--output-dir",prod_out
))
if(status!=0L)stop("Production W08 reuse script failed",call.=FALSE)

manifest<-fromJSON(file.path(prod_out,"workflow08_reuse_manifest.json"),simplifyVector=FALSE)
if(as.integer(manifest$current_issues)!=330L)stop("Expected 330 current issues",call.=FALSE)
if(as.integer(manifest$reused_issues)!=234L)stop("Expected 234 reused issues",call.=FALSE)
if(as.integer(manifest$pending_issues)!=96L)stop("Expected 96 pending issues",call.=FALSE)
if(as.integer(manifest$compatible_geography_vocabulary_migrations)!=69L)stop("Expected 69 compatibility migrations",call.=FALSE)

out<-read_jsonl(file.path(prod_out,"workflow08_reused_decisions.jsonl"))
compat<-Filter(function(z)identical(clean((z$reuse%||%list())$basis),"compatible_geography_vocabulary_migration"),out)
if(length(compat)!=69L)stop("Expected 69 compatibility-tagged decisions",call.=FALSE)
types<-vapply(compat,function(z)clean(z$issue_type),character(1))
if(sum(types=="geography_unresolved")!=59L)stop("Expected 59 migrated geography_unresolved decisions",call.=FALSE)
if(sum(types=="geography_evidence_unvalidated")!=10L)stop("Expected 10 migrated geography_evidence_unvalidated decisions",call.=FALSE)
if(any(!types%in%c("geography_unresolved","geography_evidence_unvalidated")))stop("Unexpected compatibility issue type",call.=FALSE)

# Existing substantive decisions are unchanged by adding a new option.
decs<-vapply(compat,function(z)clean(z$decision),character(1))
expected_decisions<-c("accept_model","override_country_set","assign_none")
if(any(!decs%in%expected_decisions))stop("Unexpected historical decision code after migration",call.=FALSE)

# Every migrated decision must carry the new current issue hash.
cur_hash<-list()
for(rec in queue){
  rid<-clean(rec$record_id)
  for(issue in rec$issues%||%list()){
    cur_hash[[paste(rid,clean(issue$issue_type),sep="::")]]<-clean(issue$issue_state_sha256)
  }
}
if(any(vapply(compat,function(z)!identical(tolower(clean(z$issue_state_sha256)),tolower(cur_hash[[clean(z$review_key)]])),logical(1)))){
  stop("Migrated decision was not stamped with current issue hash",call.=FALSE)
}

# Validate the production contracts contain record-level geography exclusion.
builder<-readLines("scripts/updater/workflow_08_build_review_queue_dynamic.R",warn=FALSE,encoding="UTF-8")
finalizer<-readLines("scripts/updater/workflow_08_finalize_canonical_dynamic.R",warn=FALSE,encoding="UTF-8")
required_builder<-c(
  'allowed_human_outcomes=c("assign_country_set","assign_none","exclude_record")',
  'allowed_human_outcomes=c("accept_model","override_country_set","assign_none","exclude_record")'
)
if(any(!vapply(required_builder,function(z)any(grepl(z,builder,fixed=TRUE)),logical(1))))stop("Builder geography exclude contract missing",call.=FALSE)
required_finalizer<-c(
  'if(identical(gdec,"exclude_record"))',
  'screening$final_included<-FALSE',
  'screening$exclusion_stage<-"workflow08"',
  'screening$exclusion_reason<-"geography_human_exclusion"',
  'geography$workflow08_adjudication<-gd'
)
if(any(!vapply(required_finalizer,function(z)any(grepl(z,finalizer,fixed=TRUE)),logical(1))))stop("Finalizer geography exclusion contract missing",call.=FALSE)

summary<-list(
 schema="living-evidence-map-w08-geography-record-exclusion-validation-v1",
 status="PASS",
 model_calls=0L,
 current_issues=330L,
 geography_issues=119L,
 reused_issues=234L,
 pending_issues=96L,
 compatibility_migrations=69L,
 migrated_geography_unresolved=59L,
 migrated_geography_evidence_unvalidated=10L,
 non_geography_compatibility_reuse=0L,
 geography_exclude_record_contract=TRUE,
 production_reuse_script="scripts/updater/workflow_08_reuse_decisions.R",
 production_finalizer="scripts/updater/workflow_08_finalize_canonical_dynamic.R",
 validated_at_utc=format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ")
)
write_json(summary,file.path(out_dir,"summary.json"),auto_unbox=TRUE,pretty=TRUE)
cat(toJSON(summary,auto_unbox=TRUE,pretty=TRUE),"\n")
