#!/usr/bin/env Rscript
suppressPackageStartupMessages(library(yaml))
w<-yaml::read_yaml(".github/workflows/workflow_01_production.yml")
jobs<-w$jobs
stopifnot(identical(names(jobs),c("prepare","adjudicate","canonicalise","publish")))
names_for<-function(job) vapply(jobs[[job]]$steps,function(x) if(is.null(x$name)) "" else x$name,character(1))
get_step<-function(job,name){
  a<-Filter(function(x)identical(x$name,name),jobs[[job]]$steps)
  stopifnot(length(a)==1L);a[[1L]]
}
for(stage in c("prepare","adjudicate","canonicalise")){
  s<-get_step(stage,paste("Transfer stage",stage,"working state"))
  stopifnot(identical(s$uses,"actions/upload-artifact@v4"))
}
paths<-function(stage){
  x<-get_step(stage,paste("Transfer stage",stage,"working state"))$with$path
  trimws(strsplit(x,"\n",fixed=TRUE)[[1L]])
}
p<-paths("prepare");a<-paths("adjudicate");c<-paths("canonicalise")
stopifnot(all(c("previous_state/","current_sources/","outputs/workflow01_union/",
                "outputs/workflow01_candidates/")%in%p),
          all(c("previous_state/","current_sources/","outputs/workflow01_union/",
                "outputs/workflow01_pre_adjudication/","outputs/adjudication/")%in%a),
          all(c("previous_state/","outputs/workflow01_union/",
                "outputs/final/","outputs/canonical/",
                "outputs/human_gate/normalised/data_quality_repairs.normalised.jsonl")%in%c),
          !("current_workflow00/"%in%unlist(list(p,a,c))),
          !("outputs/"%in%unlist(list(p,a,c))),
          !("current_sources/"%in%c),
          !("outputs/workflow01_pre_adjudication/"%in%c))
for(stage in c("prepare","adjudicate","canonicalise")){
  handoff<-get_step(stage,paste("Record handoff integrity (",stage,")",sep=""))$run
  stopifnot(grepl("sha256sum",handoff,fixed=TRUE))
  restored<-get_step(switch(stage,prepare="adjudicate",adjudicate="canonicalise",canonicalise="publish"),
                     "Validate restored handoff")$run
  stopifnot(grepl(paste0("workflow01_stage_",stage,"_checksums.txt"),restored,fixed=TRUE))
}
publish<-get_step("publish","Validate final state and build delta")$run
required<-c("previous_state","outputs/workflow01_union","outputs/final",
            "outputs/canonical/records.jsonl","outputs/canonical/canonical_manifest.json",
            "outputs/human_gate/normalised/data_quality_repairs.normalised.jsonl")
stopifnot(all(vapply(required,function(x)grepl(x,publish,fixed=TRUE),logical(1))))
stopifnot(!any(grepl("workflow01_candidates/",names_for("publish"),fixed=TRUE)))
cat("PASS: W01 minimum handoff manifests preserve next-stage dependencies and integrity gates\n")
