#!/usr/bin/env Rscript
suppressPackageStartupMessages({library(jsonlite);library(digest)})

args<-commandArgs(trailingOnly=TRUE)
arg<-function(flag,default=NULL){i<-match(flag,args);if(is.na(i))return(default);if(i==length(args))stop(sprintf("Missing value after %s",flag),call.=FALSE);args[[i+1L]]}
canonical_path<-arg("--canonical")
repair_path<-arg("--repairs")
output_path<-arg("--output")
manifest_path<-arg("--manifest")
force_ids_path<-arg("--force-rescreen-record-ids")
if(any(vapply(list(canonical_path,repair_path,output_path,manifest_path,force_ids_path),is.null,logical(1))))stop("Required: --canonical --repairs --output --manifest --force-rescreen-record-ids",call.=FALSE)
if(!file.exists(canonical_path)||!file.exists(repair_path))stop("Canonical or repair input missing",call.=FALSE)

`%||%`<-function(x,y)if(is.null(x))y else x
scalar<-function(x){if(is.null(x)||!length(x))return("");z<-as.character(x[[1L]]);if(is.na(z))"" else trimws(z)}
read_jsonl<-function(path){
  x<-readLines(path,warn=FALSE,encoding="UTF-8");x<-x[nzchar(trimws(x))]
  lapply(seq_along(x),function(i)tryCatch(fromJSON(x[[i]],simplifyVector=FALSE),error=function(e)stop(sprintf("Invalid JSONL %s line %d: %s",path,i,conditionMessage(e)),call.=FALSE)))
}
norm_doi<-function(x){
  x<-tolower(trimws(scalar(x)));x<-sub("^https?://(dx\\.)?doi\\.org/","",x);x<-sub("^doi[: ]*","",x);x
}
rid<-function(r)scalar((r$identity%||%list())$record_id)

canonical<-read_jsonl(canonical_path)
repairs<-read_jsonl(repair_path)
ids<-vapply(canonical,rid,character(1))
if(any(!nzchar(ids))||anyDuplicated(ids))stop("Canonical record_id invariant failed",call.=FALSE)
cmap<-setNames(seq_along(canonical),ids)

repair_ids<-vapply(repairs,function(x)scalar(x$record_id),character(1))
if(any(!nzchar(repair_ids))||anyDuplicated(repair_ids))stop("Repair record_id invariant failed",call.=FALSE)
missing<-setdiff(repair_ids,ids)
if(length(missing))stop(sprintf("%d repair IDs are absent from current canonical",length(missing)),call.=FALSE)

audit<-vector("list",length(repairs))
for(i in seq_along(repairs)){
  rp<-repairs[[i]]
  id<-repair_ids[[i]]
  j<-cmap[[id]]
  r<-canonical[[j]]
  c<-r$canonical%||%list()
  current_doi<-norm_doi(c$doi%||%r$doi)
  repair_doi<-norm_doi(rp$doi)
  if(nzchar(repair_doi)&&nzchar(current_doi)&&!identical(repair_doi,current_doi))stop(sprintf("DOI mismatch for %s",id),call.=FALSE)

  new_title<-scalar(rp$title)
  new_abstract<-scalar(rp$abstract)
  old_title<-scalar(c$title%||%r$title)
  old_abstract<-scalar(c$abstract%||%r$abstract)

  if(nzchar(new_title)&&nzchar(old_title))stop(sprintf("Repair attempts to overwrite non-missing title for %s",id),call.=FALSE)
  if(nzchar(new_abstract)&&nzchar(old_abstract))stop(sprintf("Repair attempts to overwrite non-missing abstract for %s",id),call.=FALSE)
  if(!nzchar(new_title)&&!nzchar(new_abstract))stop(sprintf("Repair provides no missing field for %s",id),call.=FALSE)

  if(is.null(r$canonical)||!is.list(r$canonical))r$canonical<-list()
  if(nzchar(new_title))r$canonical$title<-new_title
  if(nzchar(new_abstract))r$canonical$abstract<-new_abstract
  if(is.null(r$canonical$field_provenance)||!is.list(r$canonical$field_provenance))r$canonical$field_provenance<-list()
  src<-scalar(rp$repair_source)
  prov<-list(selection="manual_missing_field_repair",source=src,doi=if(nzchar(repair_doi))repair_doi else NULL,repair_overlay_sha256=digest(file=repair_path,algo="sha256",serialize=FALSE))
  if(nzchar(new_title))r$canonical$field_provenance$title<-prov
  if(nzchar(new_abstract))r$canonical$field_provenance$abstract<-prov
  canonical[[j]]<-r
  audit[[i]]<-list(record_id=id,doi=if(nzchar(repair_doi))repair_doi else NULL,repair_source=src,title_repaired=nzchar(new_title),abstract_repaired=nzchar(new_abstract))
}

dir.create(dirname(output_path),recursive=TRUE,showWarnings=FALSE)
con<-file(output_path,"wt",encoding="UTF-8");on.exit(close(con),add=TRUE)
for(r in canonical)writeLines(toJSON(r,auto_unbox=TRUE,null="null",na="null",digits=NA),con,useBytes=TRUE)
close(con);on.exit(NULL,add=FALSE)

dir.create(dirname(force_ids_path),recursive=TRUE,showWarnings=FALSE)
writeLines(sort(repair_ids),force_ids_path,useBytes=TRUE)
audit_path<-sub("\\.json$","_audit.jsonl",manifest_path)
con<-file(audit_path,"wt",encoding="UTF-8");on.exit(close(con),add=TRUE)
for(x in audit)writeLines(toJSON(x,auto_unbox=TRUE,null="null",na="null"),con,useBytes=TRUE)
close(con);on.exit(NULL,add=FALSE)

manifest<-list(
 schema="living-evidence-map-workflow04-manual-metadata-repair-application-v1",
 status="PASS",
 canonical_records=length(canonical),
 repair_records=length(repairs),
 title_repairs=sum(vapply(audit,function(x)isTRUE(x$title_repaired),logical(1))),
 abstract_repairs=sum(vapply(audit,function(x)isTRUE(x$abstract_repaired),logical(1))),
 input_canonical_sha256=digest(file=canonical_path,algo="sha256",serialize=FALSE),
 repair_overlay_sha256=digest(file=repair_path,algo="sha256",serialize=FALSE),
 output_canonical_sha256=digest(file=output_path,algo="sha256",serialize=FALSE),
 force_rescreen_ids_sha256=digest(file=force_ids_path,algo="sha256",serialize=FALSE),
 audit_file=basename(audit_path),
 generated_at_utc=format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ")
)
writeLines(toJSON(manifest,auto_unbox=TRUE,pretty=TRUE,null="null"),manifest_path,useBytes=TRUE)
cat(sprintf("PASS: applied %d missing-field repairs (%d titles, %d abstracts); stable record IDs preserved\n",length(repairs),manifest$title_repairs,manifest$abstract_repairs))
