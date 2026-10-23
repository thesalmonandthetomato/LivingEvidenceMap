#!/usr/bin/env Rscript
# Non-publishing Fast human review resume; preserves original scoring as immutable.
suppressPackageStartupMessages({library(data.table);library(jsonlite);library(digest)})
a<-commandArgs(trailingOnly=TRUE)
arg<-function(k){i<-match(k,a);if(is.na(i)||i==length(a))stop("Missing ",k);a[[i+1L]]}
root<-arg("--fast-root");meta<-arg("--metadata");prior<-arg("--previous-map")
old<-arg("--previous-decisions");queue<-arg("--queue");decisions<-arg("--decisions")
repairs<-arg("--repairs");out<-arg("--output-dir")
verified<-arg("--verified-shiny-return")
if(dir.exists(out)||file.exists(out))stop("Refusing overwrite")
original<-file.path(root,"adjudication","human_review_package","human_review_cases.jsonl")
scored<-file.path(root,"rescored","rescored_sample.csv")
report<-file.path(root,"run_report.json")
if(any(!file.exists(c(original,scored,report,meta,prior,old,queue,decisions,repairs,verified))))
 stop("Missing original review checkpoint or signed input")
readj<-function(p){z<-readLines(p,warn=FALSE);lapply(z[nzchar(trimws(z))],fromJSON,simplifyVector=FALSE)}
vr<-fromJSON(verified)
if(!identical(vr$status,"VERIFIED_SHINY_RETURN")||
 !identical(vr$production_publication_allowed,FALSE)||
 !identical(vr$workflow02_dispatch_allowed,FALSE)||
 !identical(vr$queue_sha256,digest(file=queue,algo="sha256"))||
 !identical(vr$decision_sha256,digest(file=decisions,algo="sha256"))||
 !identical(vr$repair_sha256,digest(file=repairs,algo="sha256")))
 stop("Shiny return certificate does not match reviewed inputs")
if(!identical(fromJSON(report)$status,"AWAITING_HUMAN_REVIEW")||
 !identical(digest(file=original,algo="sha256"),digest(file=queue,algo="sha256")))
 stop("Review input differs from frozen pending checkpoint")
q<-readj(queue);h<-readj(decisions)
# Reuse production W01's full review-state integrity gate before applying any decisions.
# Never silently drop an accepted edit from the Shiny repairs ledger.
integrity<-tempfile("w01-fast-review-integrity-",fileext=".json")
on.exit(unlink(integrity),add=TRUE)
gate<-suppressWarnings(system2(file.path(R.home("bin"),"Rscript"),
 c("scripts/updater/workflow_01_validate_human_review_state.R",
 "--queue",queue,"--decisions",decisions,"--repairs",repairs,
 "--output",integrity,"--expected-queue-sha256",digest(file=queue,algo="sha256"),
 "--require-complete","true"),stdout=TRUE,stderr=TRUE))
if(!is.null(attr(gate,"status"))&&attr(gate,"status")!=0L)
 stop("Production W01 human review integrity check failed: ",paste(gate,collapse=" | "))
if(!file.exists(integrity)||!isTRUE(fromJSON(integrity)$resume_allowed))
 stop("Production W01 integrity gate did not approve review continuation")
repair_count<-length(readj(repairs))
ids<-vapply(q,function(z)as.character(z$review_case_id),character(1))
did<-vapply(h,function(z)as.character(z$review_case_id),character(1))
if(!length(ids)||length(ids)!=length(did)||anyDuplicated(ids)||anyDuplicated(did)||
 !setequal(ids,did))stop("Incomplete or duplicate review decisions")
sha<-digest(file=queue,algo="sha256")
for(z in h)if(!identical(as.character(z$queue_sha256),sha)||
 !z$decision%in%c("duplicate","not_duplicate")||
 any(!vapply(c("reviewer","rationale","resolved_at_utc"),
 function(k)!is.null(z[[k]])&&nzchar(trimws(as.character(z[[k]]))),logical(1))))
 stop("Invalid human review decision provenance")
m<-fread(meta,colClasses=list(character=c("source","source_record_id")))
d<-fread(scored)
if(!identical(as.integer(m$idx),seq_len(nrow(m)))||
 anyDuplicated(m[,.(source,source_record_id)])||
 !all(c("record_i","record_j","rescored_classification","rescored_rule","review_route")%in%names(d)))
 stop("Invalid metadata or scored pair input")
key<-function(s,i)paste(nchar(s,type="bytes"),s,nchar(i,type="bytes"),i,sep=":")
mk<-key(m$source,m$source_record_id)
pairs<-paste(pmin(d$record_i,d$record_j),pmax(d$record_i,d$record_j),sep="::")
if(anyDuplicated(pairs))stop("Duplicate scored pairs")
pending<-which(d$rescored_classification=="review")
if(length(pending)!=length(q))stop("Scored pending review count mismatch")
for(z in q){
  id<-as.character(z$review_case_id)
  a<-z$record_i;b<-z$record_j
  i<-match(key(a$source,a$source_record_id),mk);j<-match(key(b$source,b$source_record_id),mk)
  if(anyNA(c(i,j))||i==j)stop("Human review record identity unavailable")
  idx<-match(paste(min(i,j),max(i,j),sep="::"),pairs)
  if(is.na(idx)||!(idx%in%pending))stop("Human review pair was not pending")
  stable<-paste(sort(c(paste(a$source,a$source_record_id,sep=":"),
                       paste(b$source,b$source_record_id,sep=":"))),collapse="|")
  expected<-paste0("hr-",substr(digest(stable,algo="sha256",serialize=FALSE),1,20))
  if(!identical(id,expected))stop("Review ID identity mismatch")
  if(!identical(as.character(z$pair_key),pairs[[idx]]))stop("Review numeric index shifted")
  choice<-h[[match(id,did)]]$decision
  d$rescored_classification[[idx]]<-if(choice=="duplicate")"duplicate" else "unresolved"
  d$rescored_rule[[idx]]<-paste0("human_",choice)
  d$review_route[[idx]]<-paste0("human_",choice)
}
if(any(d$rescored_classification=="review")||anyNA(d$rescored_classification))stop("Review incomplete")
dir.create(out,recursive=TRUE)
resolved<-file.path(out,"resolved_scoring.csv")
fwrite(d,resolved)
l<-match(d$record_i,m$idx);r<-match(d$record_j,m$idx)
stable<-data.table(source_i=m$source[l],source_record_id_i=m$source_record_id[l],
source_j=m$source[r],source_record_id_j=m$source_record_id[r],
rescored_classification=d$rescored_classification,rescored_rule=d$rescored_rule,
review_route=d$review_route)
fwrite(stable,file.path(out,"stable_decisions.csv"))
ledger<-file.path(out,"cumulative_decisions.csv")
status<-system2(file.path(R.home("bin"),"Rscript"),
 c("scripts/updater/experimental_w01_fast/stage_production_pair_ledger.R",
 "--previous-decisions",old,"--previous-map",prior,"--scored-decisions",resolved,
 "--metadata",meta,"--output",ledger))
if(status!=0L)stop("Cumulative ledger rejected human decisions")
write_json(list(schema="w01-fast-reviewed-scoring-v1",status="VALIDATED_RESUME_READY",
queue_sha256=sha,decision_count=length(h),repair_count=repair_count,
review_repairs_sha256=digest(file=repairs,algo="sha256"),
original_scoring_sha256=digest(file=scored,algo="sha256"),
resolved_scoring_sha256=digest(file=resolved,algo="sha256"),
publication_allowed=FALSE),file.path(out,"resume_manifest.json"),pretty=TRUE,auto_unbox=TRUE)
if(!file.copy(repairs,file.path(out,"verified_new_repairs.jsonl")))stop("Cannot preserve approved repair edits")
if(!file.copy(verified,file.path(out,"shiny_return_verified.json")))stop("Cannot preserve verified Shiny return")
cat("PASS: checked human review and staged non-publishing continuation inputs\n")
