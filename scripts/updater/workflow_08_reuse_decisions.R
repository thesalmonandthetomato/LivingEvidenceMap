#!/usr/bin/env Rscript
suppressPackageStartupMessages({library(jsonlite);library(digest);library(readr)})
args<-commandArgs(trailingOnly=TRUE)
arg<-function(flag,default=NULL){i<-match(flag,args);if(is.na(i))return(default);if(i==length(args))stop(sprintf("Missing value after %s",flag),call.=FALSE);args[[i+1L]]}
queue_path<-arg("--queue");prior_ledger_path<-arg("--prior-ledger","");prior_queue_path<-arg("--prior-queue","");output_dir<-arg("--output-dir","outputs/workflow08_reuse")
if(is.null(queue_path)||!file.exists(queue_path))stop("--queue required",call.=FALSE)
for(p in c(prior_ledger_path,prior_queue_path))if(nzchar(p)&&!file.exists(p))stop(sprintf("Missing prior W08 input: %s",p),call.=FALSE)
dir.create(output_dir,recursive=TRUE,showWarnings=FALSE)

read_jsonl<-function(path){if(!nzchar(path)||!file.exists(path))return(list());x<-readLines(path,warn=FALSE,encoding="UTF-8");x<-x[nzchar(trimws(x))];lapply(x,function(z)fromJSON(z,simplifyVector=FALSE))}
write_jsonl<-function(rows,path){con<-file(path,"wt",encoding="UTF-8");on.exit(close(con),add=TRUE);if(length(rows))for(z in rows)writeLines(toJSON(z,auto_unbox=TRUE,null="null",na="null",digits=NA),con,useBytes=TRUE)}
clean<-function(x){if(is.null(x)||!length(x))return("");z<-as.character(x[[1L]]);if(is.na(z))"" else z}
canon_hash<-function(x)digest(toJSON(x,auto_unbox=TRUE,null="null",na="null",digits=NA,pretty=FALSE),algo="sha256",serialize=FALSE)

queue<-read_jsonl(queue_path)
current<-list()
for(rec in queue){
 rid<-clean(rec$record_id)
 for(issue in rec$issues){
   key<-paste(rid,clean(issue$issue_type),sep="::")
   if(!is.null(current[[key]]))stop("Duplicate current review key: ",key,call.=FALSE)
   current[[key]]<-list(record=rec,issue=issue)
 }
}

prior_ledger<-read_jsonl(prior_ledger_path)
pdec<-list()
for(d in prior_ledger){key<-clean(d$review_key);if(!nzchar(key)||!is.null(pdec[[key]]))stop("Invalid/duplicate prior W08 decision key",call.=FALSE);pdec[[key]]<-d}

# Legacy W08 states lack issue fingerprints. Bootstrap from the exact historical locked queue.
prior_fp<-list()
if(nzchar(prior_queue_path)){
  pq<-read_jsonl(prior_queue_path)
  for(rec in pq){
    rid<-clean(rec$record_id)
    for(issue in rec$issues){
      key<-paste(rid,clean(issue$issue_type),sep="::")
      state<-list(
        review_key=key,record_id=rid,issue_type=clean(issue$issue_type),
        source_workflow=clean(issue$source_workflow),title=clean(rec$title),abstract=clean(rec$abstract),
        automated_value=issue$automated_value,allowed_human_outcomes=issue$allowed_human_outcomes
      )
      prior_fp[[key]]<-canon_hash(state)
    }
  }
}
# Future ledgers may carry the fingerprint directly.
for(key in names(pdec)){
  h<-clean(pdec[[key]]$issue_state_sha256)
  if(nzchar(h))prior_fp[[key]]<-h
}

reused<-list();pending_keys<-character();changed_keys<-character();new_keys<-character()
for(key in names(current)){
  curh<-clean(current[[key]]$issue$issue_state_sha256)
  if(!nzchar(curh))stop("Current issue lacks issue_state_sha256: ",key,call.=FALSE)
  if(!is.null(pdec[[key]])&&!is.null(prior_fp[[key]])&&identical(tolower(curh),tolower(prior_fp[[key]]))){
    d<-pdec[[key]]
    d$issue_state_sha256<-curh
    d$reuse<-list(reused=TRUE,basis="same_review_key_and_issue_state_sha256",prior_queue_sha256=clean(d$queue_sha256))
    reused[[length(reused)+1L]]<-d
  }else{
    pending_keys<-c(pending_keys,key)
    if(!is.null(pdec[[key]]))changed_keys<-c(changed_keys,key) else new_keys<-c(new_keys,key)
  }
}

# Rebuild record-grouped pending queue.
pending_records<-list()
for(rec in queue){
  rid<-clean(rec$record_id)
  keep<-Filter(function(issue)paste(rid,clean(issue$issue_type),sep="::")%in%pending_keys,rec$issues)
  if(length(keep)){z<-rec;z$issues<-keep;pending_records[[length(pending_records)+1L]]<-z}
}
write_jsonl(reused,file.path(output_dir,"workflow08_reused_decisions.jsonl"))
write_jsonl(pending_records,file.path(output_dir,"workflow08_pending_review_queue.jsonl"))

idx<-data.frame(
 review_key=names(current),
 status=vapply(names(current),function(k)if(k%in%pending_keys)if(k%in%changed_keys)"changed_requires_review" else "new_requires_review" else "reused",character(1)),
 stringsAsFactors=FALSE
)
write_csv(idx,file.path(output_dir,"workflow08_reuse_index.csv"),na="")
manifest<-list(
 schema="living-evidence-map-workflow08-decision-reuse-v1",status="PASS",
 current_issues=length(current),reused_issues=length(reused),pending_issues=length(pending_keys),
 new_issues=length(new_keys),changed_issues=length(changed_keys),
 current_review_records=length(queue),pending_review_records=length(pending_records),
 current_queue_sha256=digest(file=queue_path,algo="sha256",serialize=FALSE),
 prior_ledger_sha256=if(nzchar(prior_ledger_path))digest(file=prior_ledger_path,algo="sha256",serialize=FALSE)else NULL,
 prior_queue_sha256=if(nzchar(prior_queue_path))digest(file=prior_queue_path,algo="sha256",serialize=FALSE)else NULL,
 generated_at_utc=format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ")
)
write_json(manifest,file.path(output_dir,"workflow08_reuse_manifest.json"),auto_unbox=TRUE,pretty=TRUE,null="null")
cat(sprintf("PASS: W08 decision reuse current=%d reused=%d pending=%d new=%d changed=%d\n",length(current),length(reused),length(pending_keys),length(new_keys),length(changed_keys)))
