#!/usr/bin/env Rscript
suppressPackageStartupMessages({library(jsonlite);library(digest)})
args<-commandArgs(trailingOnly=TRUE)
arg<-function(flag,default=NULL){i<-match(flag,args);if(is.na(i))return(default);if(i==length(args))stop(sprintf("Missing value after %s",flag),call.=FALSE);args[[i+1L]]}
canonical_path<-arg("--canonical"); overlay_path<-arg("--repair-overlay"); out<-arg("--output"); audit_path<-arg("--audit")
if(any(vapply(list(canonical_path,overlay_path,out,audit_path),is.null,logical(1))))stop("Required: --canonical --repair-overlay --output --audit",call.=FALSE)
`%||%`<-function(x,y)if(is.null(x))y else x
scalar<-function(x){if(is.null(x)||!length(x))return("");z<-as.character(x[[1L]]);if(is.na(z))"" else trimws(z)}
read_jsonl<-function(path){x<-readLines(path,warn=FALSE,encoding="UTF-8");x<-x[nzchar(trimws(x))];lapply(seq_along(x),function(i)fromJSON(x[[i]],simplifyVector=FALSE))}
write_jsonl<-function(rows,path){con<-file(path,"wt",encoding="UTF-8");on.exit(close(con));for(z in rows)writeLines(toJSON(z,auto_unbox=TRUE,null="null",na="null",digits=NA),con,useBytes=TRUE)}
norm_doi<-function(x){x<-tolower(scalar(x));x<-sub("^https?://(dx\\.)?doi\\.org/","",x);x<-sub("^doi[: ]*","",x);trimws(x)}
recs<-read_jsonl(canonical_path); repairs<-read_jsonl(overlay_path)
ids<-vapply(recs,function(r)scalar((r$identity%||%list())$record_id),character(1))
if(any(!nzchar(ids))||anyDuplicated(ids))stop("Canonical record_id invariant failed",call.=FALSE)
idx<-setNames(seq_along(ids),ids)
seen<-character(); audit<-vector("list",length(repairs))
for(i in seq_along(repairs)){
  p<-repairs[[i]];rid<-scalar(p$record_id)
  if(!nzchar(rid)||rid%in%seen)stop(sprintf("Invalid/duplicate repair record_id: %s",rid),call.=FALSE)
  seen<-c(seen,rid);j<-idx[[rid]];if(is.null(j))stop(sprintf("Repair record absent from canonical: %s",rid),call.=FALSE)
  r<-recs[[j]];c<-r$canonical%||%list()
  can_doi<-norm_doi(c$doi%||%r$doi); rep_doi<-norm_doi(p$doi)
  if(!nzchar(can_doi)||!identical(can_doi,rep_doi))stop(sprintf("DOI mismatch for repair %s",rid),call.=FALSE)
  before_title<-scalar(c$title%||%r$title);before_abstract<-scalar(c$abstract%||%r$abstract)
  new_title<-scalar(p$title);new_abstract<-scalar(p$abstract)
  if(nzchar(new_title)&&nzchar(before_title))stop(sprintf("Repair would overwrite existing title for %s",rid),call.=FALSE)
  if(nzchar(new_abstract)&&nzchar(before_abstract))stop(sprintf("Repair would overwrite existing abstract for %s",rid),call.=FALSE)
  if(!nzchar(new_title)&&!nzchar(new_abstract))stop(sprintf("Repair has no substantive field for %s",rid),call.=FALSE)
  if(nzchar(new_title))c$title<-new_title
  if(nzchar(new_abstract))c$abstract<-new_abstract
  prov<-c$field_provenance%||%list()
  if(nzchar(new_title))prov$title_manual_repair<-list(source=scalar(p$repair_source),doi=rep_doi)
  if(nzchar(new_abstract))prov$abstract_manual_repair<-list(source=scalar(p$repair_source),doi=rep_doi)
  c$field_provenance<-prov;r$canonical<-c;recs[[j]]<-r
  audit[[i]]<-list(record_id=rid,doi=rep_doi,repair_source=scalar(p$repair_source),
                   title_added=nzchar(new_title),abstract_added=nzchar(new_abstract))
}
dir.create(dirname(out),recursive=TRUE,showWarnings=FALSE);write_jsonl(recs,out)
writeLines(toJSON(list(schema="living-evidence-map-workflow04-manual-repair-application-v1",status="PASS",
  records=length(repairs),title_added=sum(vapply(audit,function(x)isTRUE(x$title_added),logical(1))),
  abstract_added=sum(vapply(audit,function(x)isTRUE(x$abstract_added),logical(1))),
  input_canonical_sha256=digest(file=canonical_path,algo="sha256",serialize=FALSE),
  output_canonical_sha256=digest(file=out,algo="sha256",serialize=FALSE),
  repair_overlay_sha256=digest(file=overlay_path,algo="sha256",serialize=FALSE),
  repaired_record_ids=vapply(audit,function(x)x$record_id,character(1))),auto_unbox=TRUE,pretty=TRUE,null="null"),audit_path,useBytes=TRUE)
cat(sprintf("PASS: applied %d strict missing-field repairs; title=%d abstract=%d\n",length(repairs),
            sum(vapply(audit,function(x)isTRUE(x$title_added),logical(1))),
            sum(vapply(audit,function(x)isTRUE(x$abstract_added),logical(1)))))
