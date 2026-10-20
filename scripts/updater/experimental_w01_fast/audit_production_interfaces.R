#!/usr/bin/env Rscript
# Read-only inventory of original W01 jobs, invoked R scripts and local file arguments.
suppressPackageStartupMessages({library(yaml);library(jsonlite)})
w<-yaml::read_yaml(".github/workflows/workflow_01_production.yml")
jobs<-w$jobs
out<-list(reference="workflow01-final-architecture@8febc7b99ce1f7752c7553ed6023976a643f8621",jobs=list())
for(job in c("prepare","adjudicate","canonicalise","publish")){
 steps<-jobs[[job]]$steps
 out$jobs[[job]]<-lapply(steps,function(s){
   code<-if(is.null(s$run))"" else s$run
   lines<-strsplit(code,"\n",fixed=TRUE)[[1L]]
   scripts<-unique(unlist(regmatches(lines,gregexpr("scripts/[A-Za-z0-9_./-]+[.]R",lines,perl=TRUE))))
   options<-unique(unlist(regmatches(lines,gregexpr("--[A-Za-z][A-Za-z-]*[ ]+[^[:space:]]+",lines,perl=TRUE))))
   list(step=if(is.null(s$name))"" else s$name,
        execution=if(is.null(s$uses))"shell" else s$uses,
        scripts=as.list(scripts),file_arguments=as.list(options))
 })
}
# Detect inventory omissions rather than silently reporting a complete audit.
all_scripts <- unique(unlist(lapply(out$jobs,function(steps)
  unlist(lapply(steps,function(step)unlist(step$scripts,use.names=FALSE)),
    use.names=FALSE)),use.names=FALSE))
missing_scripts <- all_scripts[!file.exists(all_scripts)]
if(length(missing_scripts))stop(sprintf("Referenced R scripts missing: %s",
  paste(missing_scripts,collapse=", ")),call.=FALSE)
out$validation <- list(referenced_r_scripts=length(all_scripts),
  missing_referenced_r_scripts=as.list(missing_scripts),
  shell_steps=sum(vapply(out$jobs,function(steps)
    sum(vapply(steps,function(step)identical(step$execution,"shell"),logical(1))),
    integer(1))))
dir.create("scripts/updater/experimental_w01_fast/audits",recursive=TRUE,showWarnings=FALSE)
path<-"scripts/updater/experimental_w01_fast/audits/production_interface_inventory.json"
writeLines(toJSON(out,pretty=TRUE,auto_unbox=TRUE,null="null"),path)
stopifnot(length(out$jobs)==4L)
cat(sprintf("PASS: inventoried %d W01 stages and %d total steps to %s\n",length(out$jobs),sum(vapply(out$jobs,length,integer(1))),path))
