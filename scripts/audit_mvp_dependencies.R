#!/usr/bin/env Rscript
# Static, read-only dependency closure audit for the MVP and optional Shiny checkout.
# Usage: Rscript scripts/audit_mvp_dependencies.R [--shiny-root /path/to/LivingEvidenceMapAdjudication] [--output /tmp/mvp-audit.json]
suppressPackageStartupMessages(library(jsonlite))
args<-commandArgs(trailingOnly=TRUE)
getarg<-function(flag,default=NULL){i<-match(flag,args);if(is.na(i))return(default);if(i==length(args))stop(paste("Missing value for",flag));args[[i+1L]]}
shiny_root<-getarg("--shiny-root","")
output<-getarg("--output","")
root<-getwd()
errors<-character();warnings<-character();counts<-list()
all_files<-function(base)list.files(base,recursive=TRUE,all.files=TRUE,full.names=FALSE,include.dirs=FALSE,pattern=".")
files<-all_files(root)
has<-function(p)p%in%files
workflows<-list.files(".github/workflows-inert",pattern="\\.ya?ml$",full.names=TRUE)
if(!length(workflows))stop("No inert workflow definitions found")
wf_results<-lapply(workflows,function(p){
  x<-paste(readLines(p,warn=FALSE),collapse="\n")
  dep<-unique(c(
    regmatches(x,gregexpr("gh[[:space:]]+workflow[[:space:]]+run[[:space:]]+[a-zA-Z0-9_.-]+\\.ya?ml",x,perl=TRUE))[[1]],
    regmatches(x,gregexpr("uses:[[:space:]]*\\./\\.github/workflows/[a-zA-Z0-9_.-]+\\.ya?ml",x,perl=TRUE))[[1]]
  ))
  names<-unique(sub(".*[/[:space:]]","",dep))
  missing<-names[!vapply(names,function(n)has(file.path(".github/workflows-inert",n)),logical(1))]
  if(length(missing))errors<<-c(errors,paste(p,"missing workflow:",paste(missing,collapse=", ")))
  list(workflow=p,targets=names,missing=missing)
})
counts$workflow_definitions<-length(workflows)
counts$workflow_calls<-sum(vapply(wf_results,function(x)length(x$targets),integer(1)))
script_files<-files[grepl("^(scripts/|R/)",files)&grepl("\\.(R|r|py|sh)$",files)]
code_files<-c(script_files,workflows)
static<-list();comment_only<-list()
for(p in code_files){
  lines<-readLines(p,warn=FALSE,encoding="UTF-8")
  for(i in seq_along(lines)){
    matches<-regmatches(lines[[i]],gregexpr("(scripts/|R/|config/|user_input/)[a-zA-Z0-9_./-]+\\.(R|r|py|csv|json|txt|sh)",lines[[i]],perl=TRUE))[[1]]
    if(!length(matches))next
    for(m in unique(matches)){
      if(has(m))next
      item<-list(file=p,line=i,reference=m)
      if(grepl("^\\s*#",lines[[i]])){comment_only[[length(comment_only)+1L]]<-item}
      else if(grepl("^R/(input_queue|production_manifest|checkpoint_manifest|previous_workflow01_pointer|incremental_rescored_pairs|all_adjudications|human_review_package/|output-registry|manifest\\.json)",m)){
        static[[length(static)+1L]]<-c(item,list(classification="runtime-generated-or-embedded-R-expression; review manually"))
      }else{
        static[[length(static)+1L]]<-c(item,list(classification="unresolved; review manually"))
      }
    }
  }
}
counts$script_files<-length(script_files)
counts$comment_only_absent_refs<-length(comment_only)
counts$potential_runtime_or_missing_refs<-length(static)
if(length(static))warnings<-c(warnings,sprintf("%d non-comment literal references need runtime/path review",length(static)))
shiny<-NULL
if(nzchar(shiny_root)){
  if(!dir.exists(shiny_root))stop("Shiny root directory does not exist")
  shfiles<-all_files(shiny_root)
  rfiles<-shfiles[grepl("\\.R$",shfiles)]
  shiny_issues<-list()
  for(p in rfiles){
    x<-paste(readLines(file.path(shiny_root,p),warn=FALSE),collapse="\n")
    source_refs<-regmatches(x,gregexpr("source\\([[:space:]]*[\"'][^\"']+\\.R[\"']",x,perl=TRUE))[[1]]
    if(length(source_refs))for(z in source_refs){
      target<-sub("^source\\([[:space:]]*[\"']","",z)
      target<-sub("[\"']$","",target)
      base<-if(startsWith(p,"multiuser_app/"))"multiuser_app/" else ""
      if(!(paste0(base,target)%in%shfiles))shiny_issues[[length(shiny_issues)+1L]]<-list(file=p,missing=target)
    }
    if(grepl("workflow_02_resume_request_listener\\.yml",x,fixed=FALSE))shiny_issues[[length(shiny_issues)+1L]]<-list(file=p,obsolete_w02_listener_reference=TRUE)
  }
  shiny<-list(r_files=length(rfiles),issues=shiny_issues)
  if(length(shiny_issues))errors<-c(errors,"Shiny source or retired listener references found")
}else warnings<-c(warnings,"Shiny checkout not supplied; cross-repository source analysis omitted")
report<-list(schema="living-evidence-map-static-dependency-audit-v1",status=if(length(errors))"FAIL" else if(length(warnings))"PARTIAL_STATIC_PASS" else "STATIC_PASS",root=root,counts=counts,missing_workflow_targets=lapply(Filter(function(x)length(x$missing),wf_results),identity),potential_unresolved_references=static,comment_only_absent_references=comment_only,shiny=shiny,errors=errors,warnings=warnings,limitations=c("Does not execute network APIs or production workflows","Does not verify dynamic paths, conditional inputs, secrets or end-to-end record transformation","Workflow definitions remain inert"))
payload<-toJSON(report,auto_unbox=TRUE,pretty=TRUE,null="null")
if(nzchar(output)){dir.create(dirname(output),showWarnings=FALSE,recursive=TRUE);writeLines(payload,output)}else cat(payload,"\n")
if(length(errors))quit(status=1L)
