#!/usr/bin/env Rscript
suppressPackageStartupMessages({library(jsonlite);library(digest)})
args<-commandArgs(trailingOnly=TRUE)
arg<-function(flag,default=NULL){i<-match(flag,args);if(is.na(i))return(default);if(i==length(args))stop(sprintf("Missing value after %s",flag),call.=FALSE);args[[i+1L]]}
layer_path<-arg("--source-layer");canonical_path<-arg("--canonical");decisions_path<-arg("--decisions");source_summary_path<-arg("--source-summary");output_dir<-arg("--output-dir")
if(any(vapply(list(layer_path,canonical_path,decisions_path,source_summary_path,output_dir),is.null,logical(1))))stop("Required W04 human-resolution argument missing",call.=FALSE)
`%||%`<-function(x,y)if(is.null(x))y else x
scalar<-function(x){if(is.null(x)||!length(x))return("");z<-as.character(x[[1L]]);if(is.na(z))"" else trimws(z)}
readj<-function(p){x<-readLines(p,warn=FALSE,encoding="UTF-8");x<-x[nzchar(trimws(x))];lapply(x,function(z)fromJSON(z,simplifyVector=FALSE))}
writej<-function(rows,p){con<-file(p,"wt",encoding="UTF-8");on.exit(close(con));for(z in rows)writeLines(toJSON(z,auto_unbox=TRUE,null="null",na="null",digits=NA),con,useBytes=TRUE)}
layer<-readj(layer_path);canonical<-readj(canonical_path);decisions<-readj(decisions_path);src<-fromJSON(source_summary_path,simplifyVector=FALSE)
ids<-vapply(layer,function(z)scalar(z$record_id),character(1));if(any(!nzchar(ids))||anyDuplicated(ids))stop("Source W04 layer identity invariant failed",call.=FALSE)
uncertain_ids<-ids[vapply(layer,function(z)identical(scalar((z$screening%||%list())$decision),"uncertain"),logical(1))]
dids<-vapply(decisions,function(z)scalar(z$record_id),character(1));if(any(!nzchar(dids))||anyDuplicated(dids))stop("Human resolution decision identity invariant failed",call.=FALSE)
if(!setequal(dids,uncertain_ids))stop(sprintf("Human resolution decisions do not exactly cover uncertain W04 set: decisions=%d uncertain=%d",length(dids),length(uncertain_ids)),call.=FALSE)
dmap<-setNames(decisions,dids)
for(i in seq_along(layer)){
  id<-ids[[i]]
  if(!id%in%uncertain_ids)next
  d<-dmap[[id]];choice<-scalar(d$decision)
  if(!choice%in%c("retain","exclude"))stop(sprintf("Invalid human resolution for %s",id),call.=FALSE)
  layer[[i]]$screening$decision<-choice
  layer[[i]]$screening$decision_origin<-"human_adjudication_after_luna_uncertain"
  layer[[i]]$screening$requires_human_review<-FALSE
  layer[[i]]$screening$human_adjudication<-list(
    decision=choice,rationale=scalar(d$rationale),reviewer=scalar(d$reviewer),
    adjudicated_at_utc=scalar(d$adjudicated_at_utc)
  )
}
final_dec<-vapply(layer,function(z)scalar((z$screening%||%list())$decision),character(1))
if(any(!final_dec%in%c("retain","exclude")))stop("Human-resolved W04 layer still contains non-substantive decisions",call.=FALSE)
cids<-vapply(canonical,function(r)scalar((r$identity%||%list())$record_id),character(1));if(any(!nzchar(cids))||anyDuplicated(cids))stop("Canonical identity invariant failed",call.=FALSE)
cmap<-setNames(canonical,cids)
included_ids<-ids[final_dec=="retain"];excluded_ids<-ids[final_dec=="exclude"]
if(length(setdiff(ids,cids)))stop("W04 layer contains IDs absent from canonical",call.=FALSE)
dir.create(output_dir,recursive=TRUE,showWarnings=FALSE)
writej(layer,file.path(output_dir,"workflow04_final_screening_layer.jsonl"))
file.create(file.path(output_dir,"workflow04_human_review_queue.jsonl"))
writeLines(included_ids,file.path(output_dir,"workflow04_included_record_ids.txt"),useBytes=TRUE)
writeLines(excluded_ids,file.path(output_dir,"workflow04_excluded_record_ids.txt"),useBytes=TRUE)
writej(unname(cmap[included_ids]),file.path(output_dir,"workflow04_included_canonical.jsonl"))
summary<-list(
 schema="living-evidence-map-workflow04-final-screening-v3",status="PASS",
 mode=as.character(src$mode%||%"update"),canonical_records=length(canonical),
 workflow03_excluded=as.integer(src$workflow03_excluded),workflow03_eligible=length(ids),
 reused_records=as.integer(src$reused_records),newly_screened_records=as.integer(src$newly_screened_records),
 new_record_ids=as.integer(src$new_record_ids),changed_screening_input=as.integer(src$changed_screening_input),
 final_retain=length(included_ids),final_exclude=length(excluded_ids),unresolved=0L,
 inclusion_rate=if(length(ids))length(included_ids)/length(ids)else NA_real_,
 canonical_input_sha256=digest(file=canonical_path,algo="sha256",serialize=FALSE),
 complete_layer_sha256=digest(file=file.path(output_dir,"workflow04_final_screening_layer.jsonl"),algo="sha256",serialize=FALSE),
 included_record_ids_sha256=digest(file=file.path(output_dir,"workflow04_included_record_ids.txt"),algo="sha256",serialize=FALSE),
 excluded_record_ids_sha256=digest(file=file.path(output_dir,"workflow04_excluded_record_ids.txt"),algo="sha256",serialize=FALSE),
 human_resolution_records=length(decisions),
 generated_at_utc=format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ")
)
writeLines(toJSON(summary,auto_unbox=TRUE,pretty=TRUE,null="null",na="null"),file.path(output_dir,"summary.json"),useBytes=TRUE)
cat(sprintf("PASS: applied %d W04 human resolutions; retain=%d exclude=%d unresolved=0\n",length(decisions),length(included_ids),length(excluded_ids)))
