#!/usr/bin/env Rscript
# Offline regression: check the existing salmon terms and rendered W00 queries.
# Does not call databases, create jobs, or alter user_input.
suppressPackageStartupMessages(library(jsonlite))
args<-commandArgs(trailingOnly=TRUE)
arg<-function(k,default=NULL){i<-match(k,args);if(is.na(i))return(default);if(i==length(args))stop("Missing argument",call.=FALSE);args[[i+1L]]}
legacy_path<-arg("--legacy","user_input/workflow00_search_strategy.json")
generic_path<-arg("--candidate","user_input/workflow00_search_strategy.salmon_equivalence_candidate.json")
old<-fromJSON(legacy_path,simplifyVector=FALSE)
new<-fromJSON(generic_path,simplifyVector=FALSE)
stopifnot(identical(unlist(old$species_terms,use.names=FALSE),unlist(new$concepts$species$terms,use.names=FALSE)))
stopifnot(identical(unlist(old$farm_terms,use.names=FALSE),unlist(new$concepts$farming$terms,use.names=FALSE)))
stopifnot(identical(new$expression,"species AND farming"))
workspace<-tempfile("w00-salmon-equivalence-")
dir.create(workspace,recursive=TRUE)

sel<-file.path(workspace,"selection.json")
catalogue<-fromJSON("config/workflow00_ebsco_sources.json",simplifyVector=FALSE)
sources<-c("lens","scopus","openalex","agricola","pubmed","ethos","cba","epmc_preprints","wos",names(catalogue$sources))
writeLines(toJSON(list(selected_sources=as.list(sources)),auto_unbox=TRUE),sel)
old_out<-file.path(workspace,"legacy")
new_out<-file.path(workspace,"generic")
run<-function(script,arguments){
  logs<-suppressWarnings(system2("Rscript",c(script,arguments),stdout=TRUE,stderr=TRUE))
  st<-attr(logs,"status")
  if(!is.null(st)&&st!=0L)stop(sprintf("%s failed: %s",script,paste(logs,collapse="\n")),call.=FALSE)
}
run("scripts/updater/workflow_00_search_orchestrator.R",c("--run-type","full","--config",legacy_path,"--output-dir",old_out))
run("scripts/updater/workflow_00_translate_generic.R",c("--run-type","full","--config",generic_path,"--source-selection",sel,"--output-dir",new_out))
original<-fromJSON(file.path(old_out,"source_queries.json"),simplifyVector=FALSE)
candidate<-fromJSON(file.path(new_out,"source_queries.json"),simplifyVector=FALSE)
# Compare meaningful query syntax ignoring superficial whitespace and redundant grouping.
normalise<-function(s)gsub("[[:space:]]+","",s,perl=TRUE)
mismatches<-sources[!vapply(sources,function(n)identical(normalise(original[[n]]),normalise(candidate[[n]])),logical(1))]
unlink(workspace,recursive=TRUE)
for(src in sources){
  cat(sprintf("%s: %s\n",src,if(src%in%mismatches)"DIFFERENT":"EXACT EXCEPT WHITESPACE"))
}
if(length(mismatches))stop(sprintf("W00 salmon query differences require review: %s",paste(mismatches,collapse=", ")),call.=FALSE)
cat("PASS: all source query strings equal except whitespace\n")
