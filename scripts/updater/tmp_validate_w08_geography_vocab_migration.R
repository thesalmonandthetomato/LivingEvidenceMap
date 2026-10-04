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

# Build the post-change queue from the exact pre-change immutable queue:
# change only geography_unresolved allowed_human_outcomes and its resulting hash.
queue<-read_jsonl(queue_path)
geo_changed<-0L
for(i in seq_along(queue)){
  rec<-queue[[i]]
  rid<-clean(rec$record_id)
  for(j in seq_along(rec$issues%||%list())){
    issue<-rec$issues[[j]]
    if(clean(issue$issue_type)!="geography_unresolved")next
    if(!identical(as.character(issue$allowed_human_outcomes),c("assign_country_set","assign_none"))){
      stop("Unexpected pre-change geography vocabulary for ",rid,call.=FALSE)
    }
    issue$allowed_human_outcomes<-c("accept_model","override_country_set","assign_none")
    state<-list(
      review_key=paste(rid,"geography_unresolved",sep="::"),
      record_id=rid,
      issue_type="geography_unresolved",
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
new_queue<-file.path(out_dir,"current_queue_new_vocab.jsonl")
write_jsonl(queue,new_queue)

# Use the real decisions that were reusable in the successful pre-change run as
# the historical ledger. This gives exact real decision hashes/payloads.
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
if(as.integer(manifest$reused_issues)!=219L)stop("Expected 219 reused issues",call.=FALSE)
if(as.integer(manifest$pending_issues)!=111L)stop("Expected 111 pending issues",call.=FALSE)
if(as.integer(manifest$compatible_geography_vocabulary_migrations)!=54L)stop("Expected 54 compatibility migrations",call.=FALSE)

out<-read_jsonl(file.path(prod_out,"workflow08_reused_decisions.jsonl"))
compat<-Filter(function(z)identical(clean((z$reuse%||%list())$basis),"compatible_geography_unresolved_vocabulary_migration"),out)
if(length(compat)!=54L)stop("Expected 54 compatibility-tagged decisions",call.=FALSE)
if(any(vapply(compat,function(z)clean(z$issue_type)!="geography_unresolved",logical(1))))stop("Non-geography decision used compatibility path",call.=FALSE)

decs<-vapply(compat,function(z)clean(z$decision),character(1))
if(sum(decs=="assign_none")!=53L)stop("Expected 53 preserved assign_none decisions",call.=FALSE)
if(sum(decs=="override_country_set")!=1L)stop("Expected 1 migrated override_country_set decision",call.=FALSE)
if(any(!decs%in%c("assign_none","override_country_set")))stop("Unexpected migrated decision code",call.=FALSE)

# Every compatibility-reused decision must now carry the exact current issue hash.
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

summary<-list(
 schema="living-evidence-map-w08-production-geography-vocabulary-migration-validation-v1",
 status="PASS",
 model_calls=0L,
 current_issues=330L,
 reused_issues=219L,
 pending_issues=111L,
 compatibility_migrations=54L,
 preserved_assign_none=53L,
 migrated_assign_country_set_to_override_country_set=1L,
 non_geography_compatibility_reuse=0L,
 production_script="scripts/updater/workflow_08_reuse_decisions.R",
 validated_at_utc=format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ")
)
write_json(summary,file.path(out_dir,"summary.json"),auto_unbox=TRUE,pretty=TRUE)
cat(toJSON(summary,auto_unbox=TRUE,pretty=TRUE),"\n")
