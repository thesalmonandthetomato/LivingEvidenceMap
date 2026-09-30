#!/usr/bin/env Rscript
suppressPackageStartupMessages({library(jsonlite);library(digest)})

args<-commandArgs(trailingOnly=TRUE)
arg<-function(flag,default=NULL){i<-match(flag,args);if(is.na(i))return(default);if(i==length(args))stop(sprintf("Missing value after %s",flag),call.=FALSE);args[[i+1L]]}

canonical_path<-arg("--canonical")
w03_path<-arg("--workflow03-status")
reuse_path<-arg("--reused-layer")
new_path<-arg("--new-consensus","")
manual_path<-arg("--manual-decisions","")
prepare_manifest_path<-arg("--prepare-manifest")
output_dir<-arg("--output-dir","outputs/workflow04_final")

req<-c(canonical_path,w03_path,reuse_path,prepare_manifest_path)
if(any(vapply(req,function(x)is.null(x)||!nzchar(x)||!file.exists(x),logical(1))))stop("Required Workflow 04 merge inputs missing",call.=FALSE)
if(nzchar(new_path)&&!file.exists(new_path))stop("New consensus layer not found",call.=FALSE)
if(nzchar(manual_path)&&!file.exists(manual_path))stop("Manual decision file not found",call.=FALSE)
dir.create(output_dir,recursive=TRUE,showWarnings=FALSE)

`%||%`<-function(x,y)if(is.null(x))y else x
scalar<-function(x){if(is.null(x)||!length(x))return("");z<-as.character(x[[1L]]);if(is.na(z))"" else trimws(z)}
read_jsonl<-function(path){
  if(is.null(path)||!nzchar(path)||!file.exists(path))return(list())
  x<-readLines(path,warn=FALSE,encoding="UTF-8");x<-x[nzchar(trimws(x))]
  lapply(seq_along(x),function(i)fromJSON(x[[i]],simplifyVector=FALSE))
}
write_jsonl<-function(rows,path){
  con<-file(path,"wt",encoding="UTF-8");on.exit(close(con),add=TRUE)
  if(length(rows))for(x in rows)writeLines(toJSON(x,auto_unbox=TRUE,null="null",na="null",digits=NA),con,useBytes=TRUE)
}
rid_can<-function(r)scalar((r$identity %||% list())$record_id)
rid_layer<-function(r)scalar(r$record_id)
w03_excluded<-function(x)isTRUE((x$publication_status %||% list())$exclude_from_workflow04 %||% x$exclude_from_workflow04 %||% FALSE)

canonical<-read_jsonl(canonical_path)
w03<-read_jsonl(w03_path)
reuse<-read_jsonl(reuse_path)
fresh<-read_jsonl(new_path)
prep<-fromJSON(prepare_manifest_path,simplifyVector=FALSE)

cids<-vapply(canonical,rid_can,character(1))
wids<-vapply(w03,rid_layer,character(1))
if(any(!nzchar(cids))||anyDuplicated(cids))stop("Canonical record_id invariant failed",call.=FALSE)
if(any(!nzchar(wids))||anyDuplicated(wids)||!setequal(cids,wids))stop("Workflow 03 identity invariant failed",call.=FALSE)
w03map<-setNames(w03,wids)
eligible_ids<-sort(cids[!vapply(cids,function(id)w03_excluded(w03map[[id]]),logical(1))])
if(as.integer(prep$workflow03_eligible)!=length(eligible_ids))stop("Prepared/current W03 eligible count mismatch",call.=FALSE)

reuse_ids<-if(length(reuse))vapply(reuse,rid_layer,character(1))else character()
fresh_ids<-if(length(fresh))vapply(fresh,rid_layer,character(1))else character()
if(any(!nzchar(reuse_ids))||anyDuplicated(reuse_ids))stop("Reused W04 layer identity invariant failed",call.=FALSE)
if(any(!nzchar(fresh_ids))||anyDuplicated(fresh_ids))stop("Fresh W04 layer identity invariant failed",call.=FALSE)
if(length(intersect(reuse_ids,fresh_ids)))stop("Record appears in both reused and freshly screened W04 layers",call.=FALSE)
if(!setequal(c(reuse_ids,fresh_ids),eligible_ids)){
  miss<-setdiff(eligible_ids,c(reuse_ids,fresh_ids));extra<-setdiff(c(reuse_ids,fresh_ids),eligible_ids)
  stop(sprintf("W04 current-layer coverage mismatch: missing=%d extra=%d",length(miss),length(extra)),call.=FALSE)
}
if(length(reuse_ids)!=as.integer(prep$reusable_records))stop("Reused W04 count does not match prepare manifest",call.=FALSE)
if(length(fresh_ids)!=as.integer(prep$screen_queue_records))stop("Fresh W04 count does not match prepare manifest",call.=FALSE)

combined<-c(reuse,fresh)
ids<-vapply(combined,rid_layer,character(1))
m<-setNames(combined,ids)

manual<-read_jsonl(manual_path)
if(length(manual)){
  mids<-vapply(manual,function(x)scalar(x$record_id),character(1))
  if(any(!nzchar(mids))||anyDuplicated(mids))stop("Manual W04 decisions have missing/duplicate record_id",call.=FALSE)
  for(i in seq_along(manual)){
    id<-mids[[i]]
    if(is.null(m[[id]]))stop(sprintf("Manual W04 decision refers to unknown record: %s",id),call.=FALSE)
    current<-scalar((m[[id]]$screening %||% list())$decision)
    if(current!="uncertain")stop(sprintf("Manual W04 decision supplied for non-uncertain record: %s",id),call.=FALSE)
    d<-scalar(manual[[i]]$decision)
    if(!d%in%c("retain","exclude"))stop(sprintf("Invalid manual W04 decision for %s",id),call.=FALSE)
    m[[id]]$screening$decision<-d
    m[[id]]$screening$decision_origin<-"human_adjudication_after_luna_uncertain"
    m[[id]]$screening$requires_human_review<-FALSE
    m[[id]]$screening$human_adjudication<-list(
      decision=d,
      rationale=scalar(manual[[i]]$rationale),
      adjudicated_at_utc=scalar(manual[[i]]$adjudicated_at_utc)
    )
  }
}
final<-unname(m[eligible_ids])
final_dec<-vapply(final,function(x)scalar((x$screening %||% list())$decision),character(1))
if(any(!final_dec%in%c("retain","exclude","uncertain")))stop("Invalid decision in complete W04 layer",call.=FALSE)

uncertain<-final[final_dec=="uncertain"]
write_jsonl(uncertain,file.path(output_dir,"workflow04_human_review_queue.jsonl"))

status<-if(length(uncertain))"HUMAN_REVIEW_REQUIRED" else "PASS"
write_jsonl(final,file.path(output_dir,"workflow04_final_screening_layer.jsonl"))

included_ids<-eligible_ids[final_dec=="retain"]
excluded_ids<-eligible_ids[final_dec=="exclude"]
writeLines(included_ids,file.path(output_dir,"workflow04_included_record_ids.txt"),useBytes=TRUE)
writeLines(excluded_ids,file.path(output_dir,"workflow04_excluded_record_ids.txt"),useBytes=TRUE)

cmap<-setNames(canonical,cids)
included_canonical<-unname(cmap[included_ids])
write_jsonl(included_canonical,file.path(output_dir,"workflow04_included_canonical.jsonl"))

# Lossless schema-preservation check: every included object written to disk
# must be semantically identical to its complete current canonical input object.
written_included<-read_jsonl(file.path(output_dir,"workflow04_included_canonical.jsonl"))
written_ids<-if(length(written_included))vapply(written_included,rid_can,character(1))else character()
if(!identical(written_ids,included_ids))stop("Included canonical output order/identity mismatch",call.=FALSE)
for(i in seq_along(included_ids)){
  id<-included_ids[[i]]
  src<-toJSON(cmap[[id]],auto_unbox=TRUE,null="null",na="null",digits=NA)
  out<-toJSON(written_included[[i]],auto_unbox=TRUE,null="null",na="null",digits=NA)
  if(!identical(src,out))stop(sprintf("Canonical schema preservation failed for %s",id),call.=FALSE)
}

summary<-list(
  schema="living-evidence-map-workflow04-final-screening-v3",
  status=status,
  mode=as.character(prep$mode),
  canonical_records=length(canonical),
  workflow03_excluded=length(canonical)-length(eligible_ids),
  workflow03_eligible=length(eligible_ids),
  reused_records=length(reuse_ids),
  newly_screened_records=length(fresh_ids),
  new_record_ids=as.integer(prep$new_record_ids),
  changed_screening_input=as.integer(prep$changed_screening_input),
  final_retain=length(included_ids),
  final_exclude=length(excluded_ids),
  unresolved=length(uncertain),
  inclusion_rate=if(length(eligible_ids))length(included_ids)/length(eligible_ids)else NA_real_,
  canonical_input_sha256=digest(file=canonical_path,algo="sha256",serialize=FALSE),
  workflow03_input_sha256=digest(file=w03_path,algo="sha256",serialize=FALSE),
  complete_layer_sha256=digest(file=file.path(output_dir,"workflow04_final_screening_layer.jsonl"),algo="sha256",serialize=FALSE),
  included_record_ids_sha256=digest(file=file.path(output_dir,"workflow04_included_record_ids.txt"),algo="sha256",serialize=FALSE),
  excluded_record_ids_sha256=digest(file=file.path(output_dir,"workflow04_excluded_record_ids.txt"),algo="sha256",serialize=FALSE),
  canonical_schema_preservation="complete_current_canonical_objects_selected_without_reconstruction",
  generated_at_utc=format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ")
)
writeLines(toJSON(summary,auto_unbox=TRUE,pretty=TRUE,null="null",na="null",digits=NA),file.path(output_dir,"summary.json"),useBytes=TRUE)
cat(sprintf("%s: complete W04 layer eligible=%d reuse=%d screened=%d retain=%d exclude=%d unresolved=%d\n",
            status,length(eligible_ids),length(reuse_ids),length(fresh_ids),length(included_ids),length(excluded_ids),length(uncertain)))
