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

queue<-read_jsonl(queue_path)
reused<-read_jsonl(reused_path)
old_state<-list();new_hash<-list()

for(rec in queue){
  rid<-clean(rec$record_id)
  for(issue in rec$issues%||%list()){
    typ<-clean(issue$issue_type);key<-paste(rid,typ,sep="::")
    state<-list(
      review_key=key,record_id=rid,issue_type=typ,source_workflow=clean(issue$source_workflow),
      title=clean(rec$title),abstract=clean(rec$abstract),
      automated_value=issue$automated_value,allowed_human_outcomes=issue$allowed_human_outcomes
    )
    h<-canon_hash(state)
    if(tolower(h)!=tolower(clean(issue$issue_state_sha256)))stop("Could not reproduce old issue hash for ",key,call.=FALSE)
    if(typ=="geography_unresolved"){
      if(!identical(as.character(issue$allowed_human_outcomes),c("assign_country_set","assign_none")))stop("Unexpected old vocabulary for ",key,call.=FALSE)
      state2<-state;state2$allowed_human_outcomes<-c("accept_model","override_country_set","assign_none")
      check<-state2;check$allowed_human_outcomes<-state$allowed_human_outcomes
      if(!identical(toJSON(state,auto_unbox=TRUE,null="null",na="null",digits=NA,pretty=FALSE),
                    toJSON(check,auto_unbox=TRUE,null="null",na="null",digits=NA,pretty=FALSE)))stop("Substantive state differs for ",key,call.=FALSE)
      old_state[[key]]<-list(hash=h,state=state)
      new_hash[[key]]<-canon_hash(state2)
    }
  }
}

migrated<-list();stale<-character();counts<-c(assign_none=0L,assign_country_set=0L,accept_model=0L)
for(d in reused){
  if(clean(d$issue_type)!="geography_unresolved")next
  key<-clean(d$review_key)
  if(is.null(old_state[[key]]))stop("Reused geography decision absent from old queue: ",key,call.=FALSE)
  if(tolower(clean(d$issue_state_sha256))!=tolower(old_state[[key]]$hash)){stale<-c(stale,key);next}
  dec<-clean(d$decision)
  if(!dec%in%names(counts))stop("Unexpected old decision code for ",key,": ",dec,call.=FALSE)
  counts[[dec]]<-counts[[dec]]+1L
  z<-d
  if(dec=="assign_country_set"){
    fv<-z$final_value%||%list();iso<-as.character(fv$iso3c%||%character());nm<-as.character(fv$country_names%||%character())
    if(clean(fv$geography_status)!="RESOLVED"||!length(iso)||length(iso)!=length(nm)||any(nchar(iso)!=3L))stop("Malformed legacy country-set decision for ",key,call.=FALSE)
    z$decision<-"override_country_set"
  }else if(dec=="assign_none"){
    fv<-z$final_value%||%list()
    if(clean(fv$geography_status)!="NONE")stop("Malformed legacy assign_none decision for ",key,call.=FALSE)
  }else if(dec=="accept_model"){
    av<-old_state[[key]]$state$automated_value%||%list()
    iso<-trimws(unlist(strsplit(clean(av$luna_iso3c),";",fixed=TRUE),use.names=FALSE));iso<-iso[nzchar(iso)]
    if(!length(iso))stop("Legacy accept_model has no Luna country set for ",key,call.=FALSE)
  }
  z$issue_state_sha256<-new_hash[[key]]
  z$compatibility_migration<-list(migrated=TRUE,basis="geography_unresolved_decision_vocabulary_only",prior_issue_state_sha256=old_state[[key]]$hash)
  migrated[[key]]<-z
}

if(length(stale))stop("Expected reused geography decisions had stale issue hashes",call.=FALSE)
if(length(migrated)!=54L)stop("Expected 54 migratable geography_unresolved decisions, got ",length(migrated),call.=FALSE)
if(counts[["assign_none"]]!=53L||counts[["assign_country_set"]]!=1L)stop("Unexpected decision mix in migration test",call.=FALSE)

for(d in reused){
  if(clean(d$review_key)%in%names(migrated)&&clean(d$issue_type)!="geography_unresolved")stop("Non-geography decision touched",call.=FALSE)
}

con<-file(file.path(out_dir,"migrated_decisions.jsonl"),"wt",encoding="UTF-8")
for(z in migrated)writeLines(toJSON(z,auto_unbox=TRUE,null="null",na="null",digits=NA),con,useBytes=TRUE)
close(con)

summary<-list(
 schema="living-evidence-map-w08-geography-vocabulary-migration-validation-v1",status="PASS",model_calls=0L,
 validated_real_decisions=length(migrated),preserved_assign_none=53L,migrated_assign_country_set_to_override_country_set=1L,
 preserved_accept_model=0L,stale_issue_hashes=0L,non_geography_decisions_touched=0L,
 compatibility_basis="exact old issue hash; only allowed_human_outcomes changes",
 validated_at_utc=format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ")
)
write_json(summary,file.path(out_dir,"summary.json"),auto_unbox=TRUE,pretty=TRUE)
cat(toJSON(summary,auto_unbox=TRUE,pretty=TRUE),"\n")
