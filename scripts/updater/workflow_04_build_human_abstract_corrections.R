#!/usr/bin/env Rscript
suppressPackageStartupMessages({library(jsonlite);library(digest)})

args<-commandArgs(trailingOnly=TRUE)
arg<-function(flag,default=NULL){i<-match(flag,args);if(is.na(i))return(default);if(i==length(args))stop(sprintf("Missing value after %s",flag),call.=FALSE);args[[i+1L]]}
decisions_path<-arg("--decisions");canonical_path<-arg("--canonical");output_path<-arg("--output");manifest_path<-arg("--manifest");source_run_id<-arg("--source-run-id","")
if(any(vapply(list(decisions_path,canonical_path,output_path,manifest_path),is.null,logical(1))))stop("Required arguments missing",call.=FALSE)

`%||%`<-function(x,y)if(is.null(x))y else x
scalar<-function(x){if(is.null(x)||!length(x))return("");z<-as.character(x[[1L]]);if(is.na(z))"" else trimws(gsub("[[:space:]]+"," ",z))}
norm_doi<-function(x){
 z<-tolower(scalar(x));if(!nzchar(z))return("")
 z<-sub("^https?://(dx\\.)?doi\\.org/","",z,perl=TRUE)
 z<-sub("^doi:\\s*","",z,perl=TRUE);z<-sub("[?#].*$","",z,perl=TRUE)
 z<-sub("\\.(html?|pdf|xml)$","",z,perl=TRUE,ignore.case=TRUE);z<-sub("[.,;:]+$","",z,perl=TRUE)
 z
}
norm_title<-function(x){tolower(trimws(gsub("[[:space:]]+"," ",scalar(x))))}
readjl<-function(p){x<-readLines(p,warn=FALSE,encoding="UTF-8");x<-x[nzchar(trimws(x))];lapply(x,function(z)fromJSON(z,simplifyVector=FALSE))}
writejl<-function(xs,p){dir.create(dirname(p),recursive=TRUE,showWarnings=FALSE);con<-file(p,"wt",encoding="UTF-8");on.exit(close(con));for(x in xs)writeLines(toJSON(x,auto_unbox=TRUE,null="null",na="null",digits=NA),con,useBytes=TRUE)}

decisions<-readjl(decisions_path);canonical<-readjl(canonical_path)
cids<-vapply(canonical,function(r)scalar((r$identity%||%list())$record_id),character(1))
if(any(!nzchar(cids))||anyDuplicated(cids))stop("Canonical identity invariant failed",call.=FALSE)
cmap<-setNames(canonical,cids)
edits<-Filter(function(d)nzchar(scalar(d$edited_abstract)),decisions)
rows<-lapply(edits,function(d){
 id<-scalar(d$record_id);r<-cmap[[id]]
 if(is.null(r))stop(sprintf("Edited W04 record absent from canonical input: %s",id),call.=FALSE)
 c<-r$canonical%||%list();doi<-scalar(c$doi);title<-scalar(c$title)
 if(!nzchar(title))title<-scalar(r$title)
 nd<-norm_doi(doi);nt<-norm_title(title)
 if(!nzchar(nd)&&!nzchar(nt))stop(sprintf("Edited W04 record has neither DOI nor title: %s",id),call.=FALSE)
 list(
  schema="living-evidence-map-w04-human-abstract-correction-v1",
  record_id_at_edit=id,
  decision=scalar(d$decision),
  doi=if(nzchar(doi))doi else NULL,
  doi_normalized=if(nzchar(nd))nd else NULL,
  title=title,
  title_normalized=nt,
  edited_abstract=scalar(d$edited_abstract),
  abstract_edit_id=scalar(d$abstract_edit_id),
  abstract_edit_reviewer=scalar(d$abstract_edit_reviewer),
  abstract_edit_saved_at_utc=scalar(d$abstract_edit_saved_at_utc),
  source_w04_resume_run_id=as.character(source_run_id)
 )
})
doi_keys<-vapply(rows,function(x)scalar(x$doi_normalized),character(1))
title_keys<-vapply(rows,function(x)scalar(x$title_normalized),character(1))
if(anyDuplicated(doi_keys[nzchar(doi_keys)]))stop("Human abstract correction DOI identities are not unique",call.=FALSE)
fallback_titles<-title_keys[!nzchar(doi_keys)]
if(any(!nzchar(fallback_titles))||anyDuplicated(fallback_titles))stop("Human abstract correction DOI-less title identities are not unique",call.=FALSE)
writejl(rows,output_path)
manifest<-list(
 schema="living-evidence-map-w04-human-abstract-corrections-manifest-v1",status="PASS",
 source_w04_resume_run_id=as.character(source_run_id),corrections=length(rows),
 retain=sum(vapply(rows,function(x)identical(x$decision,"retain"),logical(1))),
 exclude=sum(vapply(rows,function(x)identical(x$decision,"exclude"),logical(1))),
 with_doi=sum(nzchar(doi_keys)),title_fallback=sum(!nzchar(doi_keys)),
 identity_rule="normalized DOI first; otherwise unique normalized title",
 corrections_sha256=digest(file=output_path,algo="sha256",serialize=FALSE)
)
writeLines(toJSON(manifest,auto_unbox=TRUE,pretty=TRUE,null="null"),manifest_path,useBytes=TRUE)
cat(sprintf("PASS: preserved %d W04 human abstract corrections (%d DOI; %d title fallback)\n",length(rows),sum(nzchar(doi_keys)),sum(!nzchar(doi_keys))))
