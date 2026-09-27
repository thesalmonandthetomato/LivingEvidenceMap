#!/usr/bin/env Rscript
suppressPackageStartupMessages({library(jsonlite);library(digest)})
args<-commandArgs(trailingOnly=TRUE)
arg<-function(flag,default=NULL){i<-match(flag,args);if(is.na(i))return(default);if(i==length(args))stop(sprintf("Missing value after %s",flag),call.=FALSE);args[[i+1L]]}
queue_path<-arg("--queue"); prior_path<-arg("--prior-decisions"); spec_path<-arg("--offline-spec")
out_path<-arg("--output"); complete_path<-arg("--complete")
if(any(vapply(list(queue_path,prior_path,spec_path,out_path,complete_path),is.null,logical(1)))) stop("Required: --queue --prior-decisions --offline-spec --output --complete",call.=FALSE)
`%||%`<-function(x,y) if(is.null(x)||length(x)==0L)y else x
read_jsonl<-function(path){x<-readLines(path,warn=FALSE,encoding="UTF-8");x<-x[nzchar(trimws(x))];lapply(x,fromJSON,simplifyVector=FALSE)}
clean<-function(x){z<-as.character(x %||% "");if(length(z)==0L||is.na(z[[1L]]))"" else z[[1L]]}
queue<-read_jsonl(queue_path); spec<-fromJSON(spec_path,simplifyVector=FALSE)
qsha<-digest(file=queue_path,algo="sha256",serialize=FALSE)
if(!identical(tolower(qsha),tolower(clean(spec$locked_queue_sha256)))) stop("Offline spec queue SHA does not match locked queue",call.=FALSE)
issues<-list()
for(rec in queue){rid<-clean(rec$record_id);for(issue in rec$issues){key<-paste(rid,clean(issue$issue_type),sep="::");if(!is.null(issues[[key]]))stop("Duplicate review key in queue: ",key,call.=FALSE);issues[[key]]<-list(record_id=rid,issue=issue)}}
if(length(issues)!=811L)stop(sprintf("Expected 811 locked queue issues; found %d",length(issues)),call.=FALSE)
prior<-read_jsonl(prior_path); out<-list()
for(d in prior){key<-clean(d$review_key);if(!nzchar(key)||is.null(issues[[key]]))stop("Prior decision not in locked queue: ",key,call.=FALSE);if(!is.null(out[[key]]))stop("Duplicate prior decision: ",key,call.=FALSE);out[[key]]<-d}
if(length(out)!=57L)stop(sprintf("Expected 57 prior locked-queue decisions; found %d",length(out)),call.=FALSE)
final_for_default<-function(key,decision,explicit=NULL){
  qi<-issues[[key]]$issue; av<-qi$automated_value
  if(!is.null(explicit))return(explicit)
  if(decision=="accept_retained_topics"){p<-av$pathways %||% list();ids<-vapply(Filter(function(z)isTRUE(z$retained_for_analysis),p),function(z)clean(z$path_id),character(1));return(list(included=TRUE,path_ids=ids))}
  if(decision%in%c("include_uncoded","no_code"))return(list(included=TRUE,path_ids=character()))
  if(decision=="exclude_record")return(list(included=FALSE))
  stop("No derivation rule for offline default decision: ",decision,call.=FALSE)
}
sheet_type<-c(geography_unresolved="geography_unresolved",species_none="species_none",topic_extreme_disagreement="topic_extreme_disagreement",zero_topic_eligibility_uncertain="zero_topic_eligibility_uncertain")
offline_n<-0L
for(sname in names(sheet_type)){
  s<-spec$sheets[[sname]];itype<-sheet_type[[sname]]
  keys<-names(issues)[vapply(issues,function(z)identical(clean(z$issue$issue_type),itype),logical(1))]
  pending<-setdiff(keys,names(out))
  if(length(pending)!=as.integer(s$expected_rows))stop(sprintf("%s expected %d pending rows; found %d",sname,as.integer(s$expected_rows),length(pending)),call.=FALSE)
  ovs<-s$overrides %||% list()
  for(key in pending){rid<-issues[[key]]$record_id;ov<-ovs[[rid]];decision<-clean(if(!is.null(ov))ov$decision else s$default$decision);explicit<-if(!is.null(ov))ov$final_value else s$default$final_value;fv<-final_for_default(key,decision,explicit)
    out[[key]]<-list(review_key=key,record_id=rid,issue_type=itype,decision=decision,final_value=fv,rationale="Offline Workflow 08 human review workbook decision.",reviewer=clean(spec$reviewed_by),resolved_at_utc=paste0(clean(spec$review_date),"T00:00:00Z"),queue_sha256=qsha,source_workbook=clean(spec$source_workbook),source_workbook_sha256=clean(spec$source_workbook_sha256));offline_n<-offline_n+1L
  }
}
if(offline_n!=as.integer(spec$expected_offline_decisions))stop("Offline decision count mismatch",call.=FALSE)
if(length(out)!=811L||!setequal(names(out),names(issues)))stop("Complete decision coverage failed",call.=FALSE)
for(key in names(out)){
  d<-out[[key]];av<-issues[[key]]$issue$automated_value
  if(is.null(d$final_value)){
    if(d$decision=="accept_model"){
      st<-clean(av$geography_status);splitv<-function(x){z<-trimws(strsplit(clean(x),";",fixed=TRUE)[[1]]);z[nzchar(z)]}
      if(st=="RESOLVED")d$final_value<-list(geography_status="RESOLVED",iso3c=splitv(av$luna_iso3c),country_names=splitv(av$luna_country_names)) else if(st=="NONE")d$final_value<-list(geography_status="NONE",iso3c=character(),country_names=character()) else stop("Cannot derive accept_model geography final_value for ",key,call.=FALSE)
    } else if(d$decision=="accept_retained_topics") d$final_value<-final_for_default(key,d$decision,NULL) else stop("Decision missing final_value: ",key,call.=FALSE)
    out[[key]]<-d
  }
  allowed<-issues[[key]]$issue$allowed_human_outcomes %||% character()
  if(!(d$decision%in%c(allowed,"no_code")))stop("Decision not allowed by locked queue: ",key," -> ",d$decision,call.=FALSE)
  if(d$decision=="no_code"&&!identical(d$issue_type,"topic_extreme_disagreement"))stop("no_code only valid for topic disagreement",call.=FALSE)
  if(!identical(tolower(clean(d$queue_sha256)),tolower(qsha)))stop("Decision queue SHA mismatch: ",key,call.=FALSE)
}
ord<-names(issues);dir.create(dirname(out_path),recursive=TRUE,showWarnings=FALSE);con<-file(out_path,"wt",encoding="UTF-8");for(key in ord)writeLines(toJSON(out[[key]],auto_unbox=TRUE,null="null",na="null"),con,useBytes=TRUE);close(con)
dsha<-digest(file=out_path,algo="sha256",serialize=FALSE)
complete<-list(schema="living-evidence-map-workflow08-complete-v1",status="PASS",locked_queue_sha256=qsha,resolved_issues=811L,unique_records=length(queue),prior_in_chat_decisions=57L,offline_workbook_decisions=offline_n,source_workbook=clean(spec$source_workbook),source_workbook_sha256=clean(spec$source_workbook_sha256),human_decisions_sha256=dsha,completed_at_utc=format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ"))
writeLines(toJSON(complete,auto_unbox=TRUE,pretty=TRUE,null="null"),complete_path,useBytes=TRUE)
cat(sprintf("PASS: expanded Workflow 08 decisions: %d issues; SHA256=%s\n",length(out),dsha))
