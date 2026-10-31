#!/usr/bin/env Rscript
# Fail-closed one-generation handoff router for W08b.
# Usage: route_after_w08.R release.json month_registry.json state.json generation output.json
# generation must be explicitly supplied by the caller: original|supplemental.
# Does not trigger actions or mutate state. Output is a requested transition.
suppressPackageStartupMessages(library(jsonlite))
`%||%`<-function(x,y)if(is.null(x)||!length(x))y else x
args<-commandArgs(trailingOnly=TRUE)
if(length(args)!=5L)stop("Usage: route_after_w08.R release.json registry.json state.json original|supplemental output.json")
release<-fromJSON(args[[1]],simplifyVector=FALSE)
registry<-fromJSON(args[[2]],simplifyVector=FALSE)
state<-if(file.exists(args[[3]]))fromJSON(args[[3]],simplifyVector=FALSE)else NULL
generation<-args[[4]]
if(!generation%in%c("original","supplemental"))stop("Unrecognised generation; fail closed")
get<-function(x){
 v<-as.character(unlist(x,use.names=FALSE))
 if(length(v)!=1L||!nzchar(v))stop("Invalid required release field")
 v
}
month<-get(release$update_month)
update<-get(release$update_id)
w08_run<-get(release$w08_run_id)
sha<-tolower(get(release$w08_canonical_sha256))
if(!grepl("^[0-9]{4}-(0[1-9]|1[0-2])$",month)||
 !grepl("^[a-f0-9]{64}$",sha)||!grepl("^[0-9]+$",w08_run))stop("Invalid W08 source release")
if(!identical(registry$schema,"workflow08b-monthly-checkpoint-registry-v1"))stop("Invalid monthly registry")
previous<-format(as.Date(paste0(month,"-01"))-1L,"%Y-%m")
eligible<-Filter(function(x)identical(as.character(x$month),previous)&&
  identical(as.character(x$status),"verified_archive"),registry$checkpoints)
if(length(eligible)!=1L)stop("No accepted previous-month checkpoint; do not dispatch")
if(!is.null(state)){
 if(!identical(state$schema,"workflow08b-monthly-routing-state-v1")||
   !identical(as.character(state$update_id),update)||
   !identical(as.character(state$update_month),month))
  stop("Routing state does not describe this exact monthly update")
}
transition<-NULL
if(generation=="original"){
 if(is.null(state)){
  transition<-"start_first_citation_generation"
 }else{
  if(!identical(as.character(state$original_w08_run_id),w08_run)||
     !identical(tolower(as.character(state$original_w08_sha256)),sha))
   stop("Repeated original W08 does not match accepted original source snapshot")
  transition<-"await_existing_citation_generation"
 }
}else{
 if(is.null(state))stop("Supplemental W08 cannot run without an accepted original citation generation")
 if(!identical(as.character(state$stage),"supplemental_w01_started"))
  stop("Supplemental W01 has not been explicitly registered")
 if(identical(as.character(state$original_w08_run_id),w08_run))
  stop("Same W08 run cannot represent both original and supplemental generation")
 if(!grepl("^[0-9]+$",as.character(state$supplemental_w01_run_id%||%"")))
  stop("Supplemental W01 provenance not registered")
 transition<-"publish_final_w09_w10"
}
result<-list(schema="workflow08b-monthly-routing-decision-v1",
 update_month=month,update_id=update,source_w08_run_id=w08_run,
 source_w08_sha256=sha,previous_checkpoint_month=previous,
 generation=generation,transition=transition,
 dispatch_w08b=identical(transition,"start_first_citation_generation"),
 dispatch_w09=identical(transition,"publish_final_w09_w10"),
 second_citation_generation_forbidden=TRUE,
 state_write_not_performed=TRUE)
dir.create(dirname(args[[5]]),recursive=TRUE,showWarnings=FALSE)
writeLines(toJSON(result,auto_unbox=TRUE,pretty=TRUE,null="null"),args[[5]])
cat("PASS: ",generation," W08 routing transition: ",transition,"\n",sep="")
