#!/usr/bin/env Rscript
suppressPackageStartupMessages({library(jsonlite);library(digest)})

args<-commandArgs(trailingOnly=TRUE)
arg<-function(flag,default=NULL){i<-match(flag,args);if(is.na(i))return(default);if(i==length(args))stop(sprintf("Missing value after %s",flag),call.=FALSE);args[[i+1L]]}
canonical_path<-arg("--canonical")
w03_path<-arg("--w03")
full_layer_path<-arg("--full-layer")
corrected_layer_path<-arg("--corrected-layer")
affected_ids_path<-arg("--affected-ids")
completed_decisions_path<-arg("--completed-decisions","")
source_summary_path<-arg("--source-summary")
output_dir<-arg("--output-dir")
if(any(vapply(list(canonical_path,w03_path,full_layer_path,corrected_layer_path,affected_ids_path,source_summary_path,output_dir),is.null,logical(1))))stop("Required argument missing",call.=FALSE)

`%||%`<-function(x,y)if(is.null(x))y else x
scalar<-function(x){if(is.null(x)||!length(x))return("");z<-as.character(x[[1L]]);if(is.na(z))"" else trimws(z)}
readj<-function(p){
  if(is.null(p)||!nzchar(p)||!file.exists(p))return(list())
  x<-readLines(p,warn=FALSE,encoding="UTF-8");x<-x[nzchar(trimws(x))]
  lapply(x,function(z)fromJSON(z,simplifyVector=FALSE))
}
writej<-function(rows,p){dir.create(dirname(p),recursive=TRUE,showWarnings=FALSE);con<-file(p,"wt",encoding="UTF-8");on.exit(close(con));if(length(rows))for(z in rows)writeLines(toJSON(z,auto_unbox=TRUE,null="null",na="null",digits=NA),con,useBytes=TRUE)}
rid_can<-function(r)scalar((r$identity%||%list())$record_id)
rid_layer<-function(r)scalar(r$record_id)
w03_excluded<-function(x)isTRUE((x$publication_status%||%list())$exclude_from_workflow04%||%x$exclude_from_workflow04%||%FALSE)

canonical<-readj(canonical_path)
w03<-readj(w03_path)
full<-readj(full_layer_path)
corrected<-readj(corrected_layer_path)
completed<-readj(completed_decisions_path)
src<-fromJSON(paste(readLines(source_summary_path,warn=FALSE,encoding="UTF-8"),collapse="\n"),simplifyVector=FALSE)
affected<-trimws(readLines(affected_ids_path,warn=FALSE,encoding="UTF-8"));affected<-sort(unique(affected[nzchar(affected)]))

cids<-vapply(canonical,rid_can,character(1))
wids<-vapply(w03,rid_layer,character(1))
fids<-vapply(full,rid_layer,character(1))
xids<-vapply(corrected,rid_layer,character(1))
if(any(!nzchar(cids))||anyDuplicated(cids))stop("Canonical identity invariant failed",call.=FALSE)
if(any(!nzchar(wids))||anyDuplicated(wids)||!setequal(cids,wids))stop("W03 identity invariant failed",call.=FALSE)
wmap<-setNames(w03,wids)
eligible<-sort(cids[!vapply(cids,function(id)w03_excluded(wmap[[id]]),logical(1))])
if(any(!nzchar(fids))||anyDuplicated(fids)||!setequal(fids,eligible))stop("Full W04 layer coverage invariant failed",call.=FALSE)
if(any(!nzchar(xids))||anyDuplicated(xids)||!setequal(xids,affected))stop(sprintf("Corrected layer/affected ID mismatch: corrected=%d affected=%d",length(xids),length(affected)),call.=FALSE)
if(length(setdiff(affected,eligible)))stop("Affected IDs outside W04-eligible set",call.=FALSE)

fm<-setNames(full,fids); xm<-setNames(corrected,xids)
old_dec<-setNames(vapply(full,function(z)scalar((z$screening%||%list())$decision),character(1)),fids)
new_dec<-setNames(vapply(corrected,function(z)scalar((z$screening%||%list())$decision),character(1)),xids)
if(any(!new_dec%in%c("retain","exclude","uncertain")))stop("Invalid corrected decision",call.=FALSE)

for(id in affected)fm[[id]]<-xm[[id]]

applied_human<-list(); skipped_human<-list()
if(length(completed)){
  dids<-vapply(completed,function(z)scalar(z$record_id),character(1))
  if(any(!nzchar(dids))||anyDuplicated(dids))stop("Completed human decision identity invariant failed",call.=FALSE)
  for(i in seq_along(completed)){
    id<-dids[[i]]
    if(is.null(fm[[id]]))stop(sprintf("Completed human decision references unknown W04 record: %s",id),call.=FALSE)
    d<-scalar(completed[[i]]$decision)
    if(!d%in%c("retain","exclude"))stop(sprintf("Invalid completed human decision for %s",id),call.=FALSE)
    current<-scalar((fm[[id]]$screening%||%list())$decision)
    if(identical(current,"uncertain")){
      fm[[id]]$screening$model_decision_before_human<-"uncertain"
      fm[[id]]$screening$model_decision_origin_before_human<-scalar((fm[[id]]$screening%||%list())$decision_origin)
      fm[[id]]$screening$model_screening_input_sha256<-scalar((fm[[id]]$screening%||%list())$screening_input_sha256)
      fm[[id]]$screening$decision<-d
      fm[[id]]$screening$decision_origin<-"human_adjudication_after_luna_uncertain"
      fm[[id]]$screening$requires_human_review<-FALSE
      fm[[id]]$screening$human_adjudication<-list(
        decision=d,rationale=scalar(completed[[i]]$rationale),reviewer=scalar(completed[[i]]$reviewer),
        adjudicated_at_utc=scalar(completed[[i]]$adjudicated_at_utc),
        reused_from_superseded_batch=TRUE,
        source_batch_id=scalar(completed[[i]]$source_batch_id),
        source_queue_sha256=scalar(completed[[i]]$source_queue_sha256)
      )
      applied_human[[length(applied_human)+1L]]<-list(record_id=id,decision=d,affected=id%in%affected)
    } else {
      skipped_human[[length(skipped_human)+1L]]<-list(record_id=id,model_decision=current,affected=id%in%affected)
    }
  }
}

final<-unname(fm[eligible])
final_dec<-vapply(final,function(z)scalar((z$screening%||%list())$decision),character(1))
if(any(!final_dec%in%c("retain","exclude","uncertain")))stop("Invalid decision in corrected complete W04 layer",call.=FALSE)
uncertain<-final[final_dec=="uncertain"]
included<-eligible[final_dec=="retain"];excluded<-eligible[final_dec=="exclude"]

dir.create(output_dir,recursive=TRUE,showWarnings=FALSE)
writej(final,file.path(output_dir,"workflow04_final_screening_layer.jsonl"))
writej(uncertain,file.path(output_dir,"workflow04_human_review_queue.jsonl"))
writeLines(included,file.path(output_dir,"workflow04_included_record_ids.txt"),useBytes=TRUE)
writeLines(excluded,file.path(output_dir,"workflow04_excluded_record_ids.txt"),useBytes=TRUE)
cmap<-setNames(canonical,cids)
writej(unname(cmap[included]),file.path(output_dir,"workflow04_included_canonical.jsonl"))

changed_model<-sum(old_dec[affected]!=new_dec[affected])
changed_to_retain<-sum(old_dec[affected]!="retain" & new_dec[affected]=="retain")
changed_to_exclude<-sum(old_dec[affected]!="exclude" & new_dec[affected]=="exclude")
changed_to_uncertain<-sum(old_dec[affected]!="uncertain" & new_dec[affected]=="uncertain")
resolved_from_uncertain<-sum(old_dec[affected]=="uncertain" & new_dec[affected]%in%c("retain","exclude"))

summary<-list(
  schema="living-evidence-map-workflow04-final-screening-v3",
  status=if(length(uncertain))"HUMAN_REVIEW_REQUIRED" else "PASS",
  mode="corrective_targeted_rescreen",
  canonical_records=length(canonical),
  workflow03_excluded=length(canonical)-length(eligible),
  workflow03_eligible=length(eligible),
  reused_records=length(eligible)-length(affected),
  newly_screened_records=length(affected),
  new_record_ids=0L,
  changed_screening_input=length(affected),
  final_retain=length(included),final_exclude=length(excluded),unresolved=length(uncertain),
  inclusion_rate=if(length(eligible))length(included)/length(eligible)else NA_real_,
  canonical_input_sha256=digest(file=canonical_path,algo="sha256",serialize=FALSE),
  workflow03_input_sha256=digest(file=w03_path,algo="sha256",serialize=FALSE),
  complete_layer_sha256=digest(file=file.path(output_dir,"workflow04_final_screening_layer.jsonl"),algo="sha256",serialize=FALSE),
  included_record_ids_sha256=digest(file=file.path(output_dir,"workflow04_included_record_ids.txt"),algo="sha256",serialize=FALSE),
  excluded_record_ids_sha256=digest(file=file.path(output_dir,"workflow04_excluded_record_ids.txt"),algo="sha256",serialize=FALSE),
  canonical_schema_preservation="complete_current_canonical_objects_selected_without_reconstruction",
  corrective_audit=list(
    affected_records=length(affected),
    corrected_model_decision_changes=changed_model,
    changed_to_retain=changed_to_retain,
    changed_to_exclude=changed_to_exclude,
    changed_to_uncertain=changed_to_uncertain,
    corrected_model_resolved_prior_uncertain=resolved_from_uncertain,
    preexisting_completed_human_decisions=length(completed),
    preexisting_human_decisions_applied=length(applied_human),
    preexisting_human_decisions_not_needed_after_corrected_model=length(skipped_human),
    remaining_human_review=length(uncertain)
  ),
  source_summary=src,
  generated_at_utc=format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ")
)
writeLines(toJSON(summary,auto_unbox=TRUE,pretty=TRUE,null="null",na="null"),file.path(output_dir,"summary.json"),useBytes=TRUE)
writeLines(toJSON(list(schema="living-evidence-map-w04-partial-abstract-correction-v1",status="PASS",audit=summary$corrective_audit,
  applied_human=applied_human,skipped_human=skipped_human),auto_unbox=TRUE,pretty=TRUE,null="null"),
  file.path(output_dir,"partial_abstract_correction_report.json"),useBytes=TRUE)
cat(toJSON(summary$corrective_audit,auto_unbox=TRUE,pretty=TRUE,null="null"),"\n")
