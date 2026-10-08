#!/usr/bin/env Rscript
# Read-only contract map of W01-W10: code calls, workflow handoffs, outputs and dynamic path markers.
args<-commandArgs(trailingOnly=TRUE)
root<-if(length(args))args[[1]] else "."
out<-if(length(args)>1L)args[[2]] else "outputs/dependency_audit"
dir.create(out,recursive=TRUE,showWarnings=FALSE)
wf<-list.files(file.path(root,".github/workflows"),pattern="\\.ya?ml$",full.names=TRUE)
wf<-wf[grepl("workflow_0[1-9]|workflow_10|report_workflow09",basename(wf))]
events<-list()
add<-function(file,line,kind,target)events[[length(events)+1L]]<<-data.frame(workflow=basename(file),line=line,kind=kind,target=target,stringsAsFactors=FALSE)
extract<-function(s,pat) {
 z<-regmatches(s,gregexpr(pat,s,perl=TRUE))[[1L]]
 if(length(z))unique(z) else character()
}
for(f in wf){
 ln<-readLines(f,warn=FALSE)
 for(i in seq_along(ln)){
  s<-ln[[i]]
  paths<-extract(s,"(?:scripts|R|config|data|docs|state|user_input|visualisations)/[A-Za-z0-9_./-]+")
  for(p in paths)add(f,i,"file-reference",p)
  scripts<-extract(s,"Rscript[[:space:]]+(?:scripts|R)/[A-Za-z0-9_./-]+\\.R")
  for(p in scripts)add(f,i,"R-execution",sub("^Rscript[[:space:]]+","",p))
  calls<-extract(s,"\\.github/workflows/[A-Za-z0-9_.-]+\\.ya?ml")
  for(p in calls)add(f,i,"workflow-call",p)
  if(grepl("gh workflow run|/actions/workflows/|workflow_dispatch",s))add(f,i,"dispatch-or-trigger",trimws(s))
  if(grepl("file\\.path\\(|find |list\\.files|paste0\\(|sprintf\\(|\\$\\{|\\$[A-Z][A-Z0-9_]+",s,perl=TRUE))add(f,i,"dynamic-or-variable-reference",trimws(substr(s,1,180)))
 }
}
tbl<-if(length(events))unique(do.call(rbind,events))else data.frame(workflow=character(),line=integer(),kind=character(),target=character())
write.csv(tbl,file.path(out,"pipeline_execution_contracts.csv"),row.names=FALSE)
manifest<-aggregate(line~workflow+kind,tbl,FUN=length)
names(manifest)[3]<-"occurrences"
write.csv(manifest,file.path(out,"pipeline_contract_summary.csv"),row.names=FALSE)
cat(sprintf("W01-W10 files inspected: %d; references and contracts: %d\n",length(wf),nrow(tbl)))
