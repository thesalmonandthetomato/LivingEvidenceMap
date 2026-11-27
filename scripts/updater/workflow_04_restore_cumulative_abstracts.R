#!/usr/bin/env Rscript
# Read-only restoration from authoritative restricted W04 correction sources.
# Never modify a canonical checkpoint or publish a correction archive here.
suppressPackageStartupMessages({library(jsonlite);library(httr2);library(digest)})
args<-commandArgs(TRUE)
arg<-function(k){i<-match(k,args);if(is.na(i)||i==length(args))stop("Missing ",k);args[[i+1L]]}
canonical<-arg("--canonical")
registry<-arg("--registry")
pointer_dir<-arg("--pointer-dir")
legacy_pointer<-arg("--legacy-pointer")
output<-arg("--output-dir")
dir.create(output,recursive=TRUE,showWarnings=FALSE)
if(length(list.files(output,all.files=TRUE,no..=TRUE)))stop("Output directory must be empty")
scalar<-function(x){if(is.null(x)||!length(x)||is.na(x[[1L]]))return("");as.character(x[[1L]])}
norm<-function(x)trimws(gsub("[[:space:]]+"," ",scalar(x)))
title<-function(x)tolower(norm(x))
doi<-function(x){
 z<-tolower(norm(x));z<-sub("^https?://(dx\\.)?doi\\.org/","",z,perl=TRUE)
 z<-sub("^doi:\\s*","",z,perl=TRUE);z<-sub("[?#].*$","",z)
 z<-sub("\\.(html?|pdf|xml)$","",z,perl=TRUE);sub("[.,;:]+$","",z)
}
readjl<-function(p){x<-readLines(p,warn=FALSE,encoding="UTF-8");lapply(x[nzchar(trimws(x))],fromJSON,simplifyVector=FALSE)}
sha<-function(p)digest(file=p,algo="sha256",serialize=FALSE)
check<-function(p,s){if(!file.exists(p)||!identical(tolower(sha(p)),tolower(scalar(s))))stop("Correction checksum mismatch: ",basename(p))}
writejl<-function(x,p){con<-file(p,"wt",encoding="UTF-8");on.exit(close(con));for(z in x)writeLines(toJSON(z,auto_unbox=TRUE,null="null",na="null",digits=NA),con,useBytes=TRUE)}
token<-Sys.getenv("ZENODO_ACCESS_TOKEN")
if(!nzchar(token))stop("Missing Zenodo token")
download<-function(record,filename,dest){
 url<-paste0("https://zenodo.org/api/records/",record,"/files/",URLencode(filename,reserved=TRUE),"/content")
 for(i in 1:5){
  r<-tryCatch(request(url)|>req_headers(Authorization=paste("Bearer",token))|>req_timeout(1800)|>req_error(is_error=function(x)FALSE)|>req_perform(path=dest),error=identity)
  if(!inherits(r,"error")&&resp_status(r)==200L)return(invisible(dest))
  if(i<5)Sys.sleep(5*i)
 }
 stop("Unable to restore restricted Zenodo record ",record)
}
sources<-list(); corrections<-list()
add<-function(file,p,n,expected,source_run){
 check(file,expected);x<-readjl(file)
 if(length(x)!=n)stop("Correction count mismatch for ",source_run)
 sources[[length(sources)+1L]]<<-list(run_id=source_run,zenodo_record_id=scalar(p$zenodo_record_id),count=n,sha256=expected,published_at_utc=scalar(p$published_at_utc))
 for(i in seq_along(x)){
  z<-x[[i]]
  z$source_archive_run_id<-source_run
  z$source_archive_sha256<-expected
  z$source_archive_row<-i
  z$source_archive_record_id<-scalar(p$zenodo_record_id)
  z$source_archive_published_at_utc<-scalar(p$published_at_utc)
  corrections[[length(corrections)+1L]]<<-z
 }
}
p<-fromJSON(legacy_pointer,simplifyVector=FALSE)
stopifnot(identical(p$status,"published"),identical(p$visibility,"restricted"))
tmp<-tempfile("w04-corrections-");dir.create(tmp)
fn<-"workflow04_human_abstract_corrections.jsonl"
dest<-file.path(tmp,fn)
download(scalar(p$zenodo_record_id),fn,dest)
add(dest,p,as.integer(p$corrections),p$corrections_sha256,scalar(p$source_w04_resume_run_id))
reg<-read.csv(registry,colClasses="character",check.names=FALSE)
stopifnot(!anyDuplicated(reg$source_github_run_id),all(nzchar(reg$source_github_run_id)))
reg<-reg[order(reg$published_at_utc,reg$source_github_run_id),,drop=FALSE]
untracked<-character()
for(i in seq_len(nrow(reg))){
 r<-reg[i,];p<-fromJSON(file.path(pointer_dir,paste0("run-",r$source_github_run_id,".json")),simplifyVector=FALSE)
 stopifnot(identical(p$status,"published"),identical(p$visibility,"restricted"),
  identical(scalar(p$source_github_run_id),r$source_github_run_id),
  identical(scalar(p$zenodo_record_id),r$zenodo_record_id),
  identical(scalar(p$manifest_sha256),r$manifest_sha256))
 if(is.null(p$human_abstract_corrections)){untracked<-c(untracked,r$source_github_run_id);next}
 n<-as.integer(p$human_abstract_corrections)
 stopifnot(length(n)==1L,!is.na(n),n>=0L)
 if(n==0L)next
 a<-p$archive_files[[1L]]
 arc<-file.path(tmp,scalar(a$filename))
 download(scalar(p$zenodo_record_id),scalar(a$filename),arc);check(arc,a$sha256)
 members<-utils::untar(arc,list=TRUE)
 if(any(grepl("^/|(^|/)\\.\\.(/|$)",members)))stop("Unsafe archive paths")
 match_file<-members[basename(members)==fn]
 if(length(match_file)!=1L)stop("Expected one correction file")
 td<-tempfile("w04-state-");dir.create(td)
 utils::untar(arc,files=match_file,exdir=td)
 add(file.path(td,match_file),p,n,p$human_abstract_corrections_sha256,r$publication_github_run_id)
 unlink(td,recursive=TRUE);unlink(arc)
}
# Reconcile by current stable identity, retaining every original event.
recs<-readjl(canonical)
ids<-vapply(recs,function(r)norm(r$identity$record_id),character(1))
ds<-vapply(recs,function(r)doi(r$canonical$doi),character(1))
ts<-vapply(recs,function(r)title(if(is.null(r$canonical$title))r$title else r$canonical$title),character(1))
stopifnot(length(ids)>0L,all(nzchar(ids)),!anyDuplicated(ids))
strip<-function(x)sub("[[:punct:][:space:]]+$","",x)
audit<-list(); chosen<-list(); conflicts<-list()
for(i in seq_along(corrections)){
 z<-corrections[[i]]
 id<-norm(z$record_id_at_edit)
 nd<-doi(if(nzchar(norm(z$doi_normalized)))z$doi_normalized else z$doi)
 nt<-title(if(nzchar(norm(z$title_normalized)))z$title_normalized else z$title)
 text<-scalar(z$edited_abstract)
 if(!nzchar(trimws(text)))stop("Empty human correction")
 k<-match(id,ids);dh<-if(nzchar(nd))which(ds==nd)else integer()
 th<-if(nzchar(nt))which(ts==nt)else integer()
 # Preserve established stable-ID plus corroborating DOI/title matching.
 j<-integer();basis<-""
 if(!is.na(k)&&((nzchar(nd)&&ds[k]==nd)||(nzchar(nt)&&ts[k]==nt))){
  j<-k;basis<-"stable_id_corroborated"
 }else if(!is.na(k)&&nzchar(nt)&&nzchar(strip(nt))&&strip(ts[k])==strip(nt)&&sum(strip(ts)==strip(nt))==1L){
  j<-k;basis<-"stable_id_unique_terminal_punctuation_title"
 }else if(length(dh)==1L&&(!length(th)||dh%in%th)){
  j<-dh;basis<-"unique_doi"
 }else if(length(intersect(dh,th))==1L){
  j<-intersect(dh,th);basis<-"doi_title"
 }else if(!length(dh)&&length(th)==1L){
  j<-th;basis<-"unique_title"
 }
 if(length(j)!=1L){conflicts[[length(conflicts)+1L]]<-list(event=i,reason="unresolved_or_conflicting_identity");next}
 key<-ids[j]
 prior<-chosen[[key]]
 # Distinct edits require strictly ordered human edit timestamps. Archive
 # publication time alone cannot prove edit precedence for overlapping data.
 stamp<-scalar(z$abstract_edit_saved_at_utc)
 if(!is.null(prior)&&!identical(norm(prior$edited_abstract),norm(text))){
  previous<-scalar(prior$abstract_edit_saved_at_utc)
  valid_time<-function(x)grepl("^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}(\\.\\d+)?Z$",x)
  if(!valid_time(stamp)||!valid_time(previous)||identical(stamp,previous)){
   conflicts[[length(conflicts)+1L]]<-list(event=i,reason="conflicting_text_without_distinct_edit_times");next
  }
  if(as.POSIXct(stamp,format="%Y-%m-%dT%H:%M:%OSZ",tz="UTC")<as.POSIXct(previous,format="%Y-%m-%dT%H:%M:%OSZ",tz="UTC")){
   audit[[length(audit)+1L]]<-list(event=i,current_record_id=key,identity_basis=basis,disposition="older_edit");next
  }
 }
 disposition<-if(is.null(prior))"new"else if(identical(norm(prior$edited_abstract),norm(text)))"duplicate_text"else "newer_edit"
 if(disposition!="duplicate_text"||(!nzchar(scalar(prior$abstract_edit_saved_at_utc))&&nzchar(stamp)))chosen[[key]]<-z
 audit[[length(audit)+1L]]<-list(event=i,current_record_id=key,identity_basis=basis,disposition=disposition)
}
# Emit only identity/provenance diagnostics, never abstract text or reviewer names.
conflict_diagnostics<-lapply(conflicts,function(x){
 z<-corrections[[x$event]]
 id<-norm(z$record_id_at_edit)
 nd<-doi(if(nzchar(norm(z$doi_normalized)))z$doi_normalized else z$doi)
 nt<-title(if(nzchar(norm(z$title_normalized)))z$title_normalized else z$title)
 k<-match(id,ids)
 dh<-if(nzchar(nd))which(ds==nd)else integer()
 th<-if(nzchar(nt))which(ts==nt)else integer()
 candidates<-unique(c(if(!is.na(k))k else integer(),dh,th))
 list(event=x$event,reason=x$reason,source_run=z$source_archive_run_id,
 source_row=z$source_archive_row,stable_id_present=!is.na(k),
 doi_matches=length(dh),title_matches=length(th),
 archived_doi_present=nzchar(nd),archived_title_present=nzchar(nt),
 current_doi_present=!is.na(k)&&nzchar(ds[k]),current_title_present=!is.na(k)&&nzchar(ts[k]),
 title_edit_distance=if(!is.na(k)&&nzchar(nt))as.integer(adist(nt,ts[k]))else NULL,
 title_lengths=if(!is.na(k))c(nchar(nt),nchar(ts[k]))else NULL,
 title_alphanumeric_agrees=!is.na(k)&&nzchar(nt)&&identical(gsub("[^[:alnum:]]","",nt),gsub("[^[:alnum:]]","",ts[k])),
 current_record_field_names=if(!is.na(k))names(recs[[k]])else NULL,
 current_identity_field_names=if(!is.na(k))names(recs[[k]]$identity)else NULL,
 current_canonical_field_names=if(!is.na(k))names(recs[[k]]$canonical)else NULL,
 stable_id_doi_agrees=!is.na(k)&&nzchar(nd)&&ds[k]==nd,
 stable_id_title_agrees=!is.na(k)&&nzchar(nt)&&ts[k]==nt,
 edit_time=scalar(z$abstract_edit_saved_at_utc),
 candidate_prior_edits=lapply(candidates,function(j){
  p<-chosen[[ids[j]]]
  list(has_prior=!is.null(p),source_run=scalar(p$source_archive_run_id),
   source_row=p$source_archive_row,edit_time=scalar(p$abstract_edit_saved_at_utc),
   same_normalized_text=!is.null(p)&&identical(norm(p$edited_abstract),norm(z$edited_abstract)),
   same_edit_id=!is.null(p)&&nzchar(scalar(z$abstract_edit_id))&&identical(scalar(p$abstract_edit_id),scalar(z$abstract_edit_id)))
 }))
})
summary<-list(status=if(length(conflicts))"FAIL"else "PASS",sources=sources,
 conflict_diagnostics=conflict_diagnostics,
 historical_pointers_without_explicit_correction_metadata=untracked,
 correction_events=length(corrections),unique_resolved_works=length(chosen),
 conflicts=length(conflicts),dispositions=as.list(table(vapply(audit,function(x)x$disposition,character(1)))))
writeLines(toJSON(summary,auto_unbox=TRUE,pretty=TRUE,null="null"),file.path(output,"summary.json"))
cat(toJSON(summary,auto_unbox=TRUE,pretty=TRUE,null="null"),"\n")
# Restricted data stays on runner. Never upload text, work IDs or correction ledger
# as unrestricted CI artifacts.
writejl(audit,file.path(output,"audit.jsonl"))
writejl(conflicts,file.path(output,"conflicts.jsonl"))
if(length(conflicts))stop("Unresolved correction conflicts; no overlay produced")
for(key in names(chosen)){
 j<-match(key,ids);z<-chosen[[key]]
 recs[[j]]$canonical$abstract<-scalar(z$edited_abstract)
 p<-recs[[j]]$canonical$field_provenance
 p$abstract_human_w04<-list(source="workflow04_human_abstract_correction",
   source_archive_run_id=z$source_archive_run_id,source_archive_record_id=z$source_archive_record_id,
   source_archive_sha256=z$source_archive_sha256,source_archive_row=z$source_archive_row,
   abstract_edit_saved_at_utc=z$abstract_edit_saved_at_utc)
 recs[[j]]$canonical$field_provenance<-p
}
writejl(recs,file.path(output,"canonical_lean.jsonl"))
writejl(corrections,file.path(output,"correction_events.jsonl"))
cat("PASS: cumulative human corrections restored without modifying source checkpoint\n")
