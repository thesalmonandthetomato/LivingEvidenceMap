#!/usr/bin/env Rscript
suppressPackageStartupMessages({library(jsonlite);library(digest)})

args<-commandArgs(trailingOnly=TRUE)
arg<-function(flag,default=NULL){i<-match(flag,args);if(is.na(i))return(default);if(i==length(args))stop(sprintf("Missing value after %s",flag),call.=FALSE);args[[i+1L]]}
queue_path<-arg("--queue");legacy_path<-arg("--legacy");output<-arg("--output")
if(any(vapply(c(queue_path,legacy_path,output),is.null,logical(1))))stop("Required: --queue --legacy --output",call.=FALSE)
for(p in c(queue_path,legacy_path))if(!file.exists(p))stop("Missing input: ",p,call.=FALSE)

read_jsonl<-function(path){x<-readLines(path,warn=FALSE,encoding="UTF-8");x<-x[nzchar(trimws(x))];lapply(x,function(z)fromJSON(z,simplifyVector=FALSE))}
clean<-function(x){if(is.null(x)||!length(x))return("");z<-as.character(x[[1L]]);if(is.na(z))"" else z}
queue<-read_jsonl(queue_path);legacy<-read_jsonl(legacy_path)

qmap<-list()
for(rec in queue){
  rid<-clean(rec$record_id)
  for(issue in rec$issues){
    key<-paste(rid,clean(issue$issue_type),sep="::")
    qmap[[key]]<-list(record=rec,issue=issue)
  }
}

out<-list()
for(z in legacy){
  rid<-clean(z$record_id)
  candidate_keys<-c(paste(rid,"geography_unresolved",sep="::"),paste(rid,"geography_evidence_unvalidated",sep="::"))
  key<-candidate_keys[vapply(candidate_keys,function(k)!is.null(qmap[[k]]),logical(1))]
  if(length(key)!=1L)stop(sprintf("Legacy geography decision %s does not map to exactly one current W08 issue",rid),call.=FALSE)
  key<-key[[1L]]
  issue<-qmap[[key]]$issue
  itype<-clean(issue$issue_type)
  final_status<-clean(z$final_status)
  final_iso<-as.character(z$final_iso3c %||% character())
  final_iso<-final_iso[nzchar(final_iso)]

  if(itype=="geography_unresolved"){
    decision<-if(final_status=="NONE")"assign_none" else "assign_country_set"
  }else{
    if(clean(z$human_decision)=="accept_model") decision<-"accept_model"
    else if(final_status=="NONE") decision<-"assign_none"
    else decision<-"override_country_set"
  }

  fv<-list(geography_status=final_status,iso3c=final_iso)
  out[[length(out)+1L]]<-list(
    review_key=key,
    record_id=rid,
    issue_type=itype,
    decision=decision,
    final_value=fv,
    rationale=clean(z$rationale),
    reviewer="Neal Haddaway",
    resolved_at_utc=paste0(clean(z$decision_date),"T00:00:00Z"),
    issue_state_sha256=clean(issue$issue_state_sha256),
    source="legacy_workflow08_geography_migration"
  )
}

dir.create(dirname(output),recursive=TRUE,showWarnings=FALSE)
con<-file(output,"wt",encoding="UTF-8");on.exit(close(con),add=TRUE)
for(z in out)writeLines(toJSON(z,auto_unbox=TRUE,null="null",na="null",digits=NA),con,useBytes=TRUE)
close(con);on.exit(NULL,add=FALSE)
cat(sprintf("PASS: migrated %d legacy W08 geography decisions to standard reusable state\n",length(out)))
