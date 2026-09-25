#!/usr/bin/env Rscript
suppressPackageStartupMessages(library(jsonlite))

args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag,default=NULL){
  i <- match(flag,args)
  if(is.na(i)) return(default)
  if(i==length(args)) stop(sprintf("Missing value after %s",flag),call.=FALSE)
  args[[i+1L]]
}

canonical_path <- arg("--canonical")
w03_path <- arg("--workflow03-status")
historical_path <- arg("--historical-records")
historical_manifest_path <- arg("--historical-manifest")
output_dir <- arg("--output-dir","outputs/workflow04_historical_migration")

if(any(vapply(list(canonical_path,w03_path,historical_path,historical_manifest_path),is.null,logical(1)))){
  stop("Required: --canonical --workflow03-status --historical-records --historical-manifest",call.=FALSE)
}
dir.create(output_dir,recursive=TRUE,showWarnings=FALSE)

`%||%` <- function(x,y) if(is.null(x)) y else x
scalar <- function(x){
  if(is.null(x)||!length(x)) return("")
  z<-as.character(x[[1L]])
  if(is.na(z)) "" else trimws(z)
}
read_jsonl <- function(path){
  if(!file.exists(path)) stop(sprintf("Missing input: %s",path),call.=FALSE)
  x<-readLines(path,warn=FALSE,encoding="UTF-8")
  x<-x[nzchar(trimws(x))]
  lapply(seq_along(x),function(i)tryCatch(
    fromJSON(x[[i]],simplifyVector=FALSE),
    error=function(e)stop(sprintf("Invalid JSONL %s line %d: %s",path,i,conditionMessage(e)),call.=FALSE)
  ))
}
write_jsonl <- function(rows,path){
  con<-file(path,"wt",encoding="UTF-8");on.exit(close(con))
  for(x in rows) writeLines(toJSON(x,auto_unbox=TRUE,null="null",na="null",digits=NA),con,useBytes=TRUE)
}
historical_lens_id <- function(r){
  scalar((r$identity %||% list())$lens_id %||% (r$canonical %||% list())$lens_id)
}
historical_rep <- function(r){
  scalar((r$deduplication %||% list())$status) %in% c("unique","canonical")
}
historical_pub_eligible <- function(r){
  n<-r$notices %||% NULL
  if(is.null(n)) return(TRUE)
  if(!is.null(n$record_downstream_eligible)) return(isTRUE(n$record_downstream_eligible))
  if(!is.null(n$downstream_eligible)) return(isTRUE(n$downstream_eligible))
  TRUE
}
historical_decision <- function(r){
  d<-tolower(scalar((r$screening %||% list())$decision))
  if(d=="include") return("retain")
  if(d=="exclude") return("exclude")
  if(d %in% c("retain","exclude")) return(d)
  ""
}
record_id <- function(r) scalar((r$identity %||% list())$record_id)
manifestation_refs <- function(r){
  x<-r$manifestation_refs %||% list()
  if(!length(x)) character() else as.character(unlist(x,use.names=FALSE))
}
lens_refs <- function(r){
  x<-manifestation_refs(r)
  sub("^lens:","",x[grepl("^lens:",x)])
}

hm<-fromJSON(historical_manifest_path,simplifyVector=FALSE)
if(!identical(scalar(hm$pipeline_stage),"relevance_screening_complete")){
  stop("Historical corpus is not the completed relevance-screening state",call.=FALSE)
}
hc<-hm$workflow04_relevance_screening_completion %||% list()
if(!identical(scalar(hc$status),"complete")) stop("Historical Workflow 04 completion marker is absent",call.=FALSE)
if(as.integer(hc$unresolved %||% -1L)!=0L) stop("Historical Workflow 04 state contains unresolved records",call.=FALSE)

historical<-read_jsonl(historical_path)
h_ids<-vapply(historical,historical_lens_id,character(1))
if(any(!nzchar(h_ids))||anyDuplicated(h_ids)) stop("Historical Lens-ID invariant failed",call.=FALSE)

h_idx<-which(vapply(historical,historical_rep,logical(1)) & vapply(historical,historical_pub_eligible,logical(1)))
h_dec<-vapply(historical[h_idx],historical_decision,character(1))
if(any(!h_dec %in% c("retain","exclude"))) stop("Completed historical representative lacks a definitive screening decision",call.=FALSE)
if(length(h_idx)!=22605L || sum(h_dec=="retain")!=16068L || sum(h_dec=="exclude")!=6537L){
  stop(sprintf("Historical completed-state totals differ from expected: n=%d retain=%d exclude=%d",
               length(h_idx),sum(h_dec=="retain"),sum(h_dec=="exclude")),call.=FALSE)
}

hist_map<-setNames(h_dec,h_ids[h_idx])
hist_record_map<-setNames(historical,h_ids)
bib_text<-function(r,field){
  can<-r$canonical %||% list()
  raw<-((r$lens %||% list())$raw_payload %||% list())
  v<-can[[field]] %||% raw[[field]] %||% r[[field]] %||% NULL
  if(is.null(v)||!length(v)) return("")
  if(is.character(v)) return(paste(v,collapse="; "))
  if(is.atomic(v)) return(paste(as.character(v),collapse="; "))
  ""
}
canonical_bib<-function(r){
  can<-r$canonical %||% list()
  list(
    title=scalar(can$title %||% r$title),
    abstract=scalar(can$abstract %||% r$abstract),
    doi=scalar(can$doi %||% (r$identity %||% list())$doi),
    year=scalar(can$year %||% r$year),
    journal=scalar(can$journal %||% can$source_title %||% r$journal)
  )
}
historical_bib<-function(id){
  r<-hist_record_map[[id]]
  if(is.null(r)) return(list(lens_id=id))
  can<-r$canonical %||% list()
  raw<-((r$lens %||% list())$raw_payload %||% list())
  list(
    lens_id=id,
    decision=unname(hist_map[[id]]),
    title=scalar(can$title %||% raw$title),
    abstract=scalar(can$abstract %||% raw$abstract),
    doi=scalar(can$doi %||% raw$doi),
    year=scalar(can$year %||% raw$year),
    journal=scalar(can$journal %||% can$source_title %||% raw$journal %||% raw$source_title)
  )
}
hist_prov<-setNames(lapply(seq_along(h_idx),function(i){
  r<-historical[[h_idx[[i]]]]
  s<-r$screening %||% list()
  list(
    historical_lens_id=h_ids[h_idx[[i]]],
    decision=h_dec[[i]],
    historical_screening_status=scalar(s$status),
    historical_workflow=scalar(s$workflow)
  )
}),h_ids[h_idx])

canonical<-read_jsonl(canonical_path)
c_ids<-vapply(canonical,record_id,character(1))
if(length(canonical)!=32292L||any(!nzchar(c_ids))||anyDuplicated(c_ids)) stop("New canonical invariant failed",call.=FALSE)

w03<-read_jsonl(w03_path)
w03_ids<-vapply(w03,function(x)scalar(x$record_id),character(1))
if(length(w03)!=32292L||any(!nzchar(w03_ids))||anyDuplicated(w03_ids)||!setequal(w03_ids,c_ids)) stop("Workflow 03 state/canonical identity invariant failed",call.=FALSE)
w03_map<-setNames(w03,w03_ids)

layer<-list();conflicts<-list();novel<-list();blocked_novel<-list();audit<-vector("list",length(canonical))
counts<-c(recovered=0L,conflict=0L,novel=0L,blocked_novel=0L,recovered_w03_excluded=0L)
used_historical_ids<-character()

for(i in seq_along(canonical)){
  r<-canonical[[i]];rid<-c_ids[[i]]
  refs<-lens_refs(r)
  matched<-intersect(refs,names(hist_map))
  decisions<-unique(unname(hist_map[matched]))
  st<-w03_map[[rid]]
  excluded<-isTRUE((st$publication_status %||% list())$exclude_from_workflow04 %||% st$exclude_from_workflow04 %||% FALSE)
  pcode<-scalar((st$publication_status %||% list())$code %||% st$code)

  if(length(decisions)==1L){
    d<-decisions[[1L]]
    counts["recovered"]<-counts["recovered"]+1L
    if(excluded) counts["recovered_w03_excluded"]<-counts["recovered_w03_excluded"]+1L
    used_historical_ids<-c(used_historical_ids,matched)
    layer[[length(layer)+1L]]<-list(
      record_id=rid,
      screening=list(
        decision=d,
        decision_origin="historical_migration",
        source_historical_lens_ids=sort(matched),
        source_historical_decisions=unname(as.list(hist_map[matched])),
        legacy_source_branch="canonical-fresh-dedup-v2-2026-09-14",
        legacy_workflow04_status="complete",
        migrated_without_rescreening=TRUE
      )
    )
    state<-"recovered"
  }else if(length(decisions)>1L){
    counts["conflict"]<-counts["conflict"]+1L
    conflicts[[length(conflicts)+1L]]<-list(
      record_id=rid,
      canonical=canonical_bib(r),
      lens_manifestation_refs=sort(refs),
      matched_historical_lens_ids=sort(matched),
      historical_decisions=unname(as.list(hist_map[matched])),
      historical_manifestations=lapply(sort(matched),historical_bib),
      workflow03_code=pcode,
      workflow03_excluded=excluded
    )
    state<-"conflict"
  }else if(excluded){
    counts["blocked_novel"]<-counts["blocked_novel"]+1L
    blocked_novel[[length(blocked_novel)+1L]]<-list(
      record_id=rid,
      lens_manifestation_refs=sort(refs),
      workflow03_code=pcode,
      reason="No recoverable historical Workflow 04 decision; currently excluded by Workflow 03"
    )
    state<-"blocked_novel"
  }else{
    counts["novel"]<-counts["novel"]+1L
    novel[[length(novel)+1L]]<-list(
      record_id=rid,
      lens_manifestation_refs=sort(refs),
      workflow03_code=pcode
    )
    state<-"novel"
  }

  audit[[i]]<-list(
    record_id=rid,
    migration_state=state,
    workflow03_code=pcode,
    workflow03_excluded=excluded,
    lens_manifestation_count=length(refs),
    matched_historical_representatives=sort(matched),
    recovered_decision=if(length(decisions)==1L)decisions[[1L]] else NULL
  )
}

if(sum(counts[c("recovered","conflict","novel","blocked_novel")])!=length(canonical)) stop("Migration partition invariant failed",call.=FALSE)

w03_excluded_total<-sum(vapply(w03,function(x)isTRUE((x$publication_status %||% list())$exclude_from_workflow04 %||% x$exclude_from_workflow04 %||% FALSE),logical(1)))
if(w03_excluded_total!=9L) stop(sprintf("Expected 9 Workflow 03 exclusions, found %d",w03_excluded_total),call.=FALSE)

eligible_total<-length(canonical)-w03_excluded_total
eligible_partition<-counts["recovered"]-counts["recovered_w03_excluded"]+counts["conflict"]+counts["novel"]
# conflicts could theoretically be W03-excluded, calculate exact eligible conflicts instead.
eligible_conflicts<-sum(vapply(conflicts,function(x)!isTRUE(x$workflow03_excluded),logical(1)))
eligible_partition<-counts["recovered"]-counts["recovered_w03_excluded"]+eligible_conflicts+counts["novel"]
if(eligible_partition!=eligible_total) stop("Workflow 03 eligible partition invariant failed",call.=FALSE)

write_jsonl(layer,file.path(output_dir,"historical_screening_layer.jsonl"))
write_jsonl(conflicts,file.path(output_dir,"historical_mapping_conflicts.jsonl"))
write_jsonl(novel,file.path(output_dir,"novel_screening_queue.jsonl"))
write_jsonl(blocked_novel,file.path(output_dir,"workflow03_blocked_without_historical_decision.jsonl"))
write_jsonl(audit,file.path(output_dir,"reconciliation_audit.jsonl"))

unused_ids<-setdiff(names(hist_map),unique(c(used_historical_ids,unlist(lapply(conflicts,function(x)x$matched_historical_lens_ids),use.names=FALSE))))
unused_rows<-lapply(sort(unused_ids),historical_bib)
write_jsonl(unused_rows,file.path(output_dir,"unused_historical_representatives.jsonl"))

summary<-list(
  schema="living-evidence-map-workflow04-historical-migration-audit-v1",
  status=if(length(conflicts)==0L)"PASS_NO_CONFLICTS" else "REVIEW_REQUIRED",
  migration_type="one_off_historical_screening_reconciliation",
  production_workflow04=FALSE,
  prompt_used=FALSE,
  llm_calls=0L,
  canonical_records=length(canonical),
  workflow03_excluded=w03_excluded_total,
  workflow03_eligible=eligible_total,
  historical_completed_representatives=length(h_idx),
  historical_retain=sum(h_dec=="retain"),
  historical_exclude=sum(h_dec=="exclude"),
  canonical_records_with_recovered_historical_decision=unname(counts["recovered"]),
  recovered_but_currently_workflow03_excluded=unname(counts["recovered_w03_excluded"]),
  canonical_records_with_conflicting_historical_decisions=unname(counts["conflict"]),
  eligible_conflicts=eligible_conflicts,
  genuinely_novel_eligible_records=unname(counts["novel"]),
  workflow03_blocked_without_historical_decision=unname(counts["blocked_novel"]),
  unique_historical_representative_ids_used=length(unique(used_historical_ids)),
  historical_representative_ids_not_used=length(setdiff(names(hist_map),unique(used_historical_ids))),
  source_historical_branch="canonical-fresh-dedup-v2-2026-09-14",
  source_historical_completion_audit_run=scalar(hc$source_audit_run),
  source_historical_prompt_version=scalar(hc$prompt_version),
  source_historical_prompt_sha256=scalar(hc$prompt_sha256),
  created_at_utc=format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ")
)
writeLines(toJSON(summary,auto_unbox=TRUE,pretty=TRUE,null="null",na="null"),
           file.path(output_dir,"reconciliation_summary.json"),useBytes=TRUE)

cat(toJSON(summary,auto_unbox=TRUE,pretty=TRUE,null="null",na="null"),"\n")
