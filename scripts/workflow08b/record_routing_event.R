#!/usr/bin/env Rscript
# Apply a validated W08b generation transition to a versioned routing marker.
# No GitHub calls or external effects; the caller commits the resulting marker.
# Usage: record_routing_event.R event release.json marker.json [supplemental_w01_run_id]
suppressPackageStartupMessages(library(jsonlite))
`%||%`<-function(x,y)if(is.null(x)||!length(x))y else x
a<-commandArgs(trailingOnly=TRUE)
if(length(a)<3L||length(a)>4L)
  stop("Usage: record_routing_event.R init|candidates_started|supplemental_w01_started|no_supplemental|completed release.json marker.json [w01_run]")
event<-a[[1]]
if(!event%in%c("init","candidates_started","supplemental_w01_started","no_supplemental","completed"))
 stop("Unknown routing transition")
release<-fromJSON(a[[2]],simplifyVector=FALSE)
marker<-a[[3]]
get<-function(x){
 v<-as.character(unlist(x,use.names=FALSE))
 if(length(v)!=1L||!nzchar(v))stop("Missing transition identity")
 v
}
update<-get(release$update_id)
month<-get(release$update_month)
w08_run<-get(release$w08_run_id)
sha<-tolower(get(release$w08_canonical_sha256))
w01_run<-get(release$w01_run_id)
if(!grepl("^[A-Za-z0-9._-]+$",update)||
 !grepl("^[0-9]{4}-(0[1-9]|1[0-2])$",month)||
 !grepl("^[0-9]+$",w08_run)||!grepl("^[0-9]+$",w01_run)||
 !grepl("^[a-f0-9]{64}$",sha))stop("Invalid original release identity")
if(event=="init"){
 if(file.exists(marker))stop("Cannot overwrite existing W08b routing state")
 state<-list(schema="workflow08b-monthly-routing-state-v1",
   update_id=update,update_month=month,
   original_w08_run_id=w08_run,original_w08_sha256=sha,
   original_w01_run_id=w01_run,stage="citation_chasing_started",
   stages_completed=list(),same_update_required=TRUE,
   second_generation_forbidden=TRUE)
}else{
 if(!file.exists(marker))stop("Transition requires existing W08b state")
 state<-fromJSON(marker,simplifyVector=FALSE)
 if(!identical(state$schema,"workflow08b-monthly-routing-state-v1")||
    !identical(as.character(state$update_id),update)||
    !identical(as.character(state$update_month),month))
   stop("Routing transition update differs from original generation")
 stage<-as.character(state$stage)
 if(event=="candidates_started"){
   if(!stage%in%c("citation_chasing_started","candidates_started"))
     stop("Cannot dispatch candidate retrieval from this routing stage")
   if(!identical(as.character(state$original_w08_sha256),sha))
     stop("Citation candidates must refer to original W08 source")
   state$stage<-"candidates_started"
 }else if(event=="supplemental_w01_started"){
   if(!stage%in%c("citation_chasing_started","candidates_started"))
     stop("Supplemental W01 cannot start twice or after publication")
   new_w01<-if(length(a)==4L)a[[4]]else w01_run
   if(!grepl("^[0-9]+$",new_w01)||
      identical(new_w01,as.character(state$original_w01_run_id)))
     stop("Supplemental W01 must have its own published lineage")
   state$supplemental_w01_run_id<-new_w01
   state$stage<-"supplemental_w01_started"
 }else if(event=="no_supplemental"){
   if(!stage%in%c("citation_chasing_started","candidates_started"))
     stop("No-candidate publication not allowed from this stage")
   if(!identical(as.character(state$original_w08_run_id),w08_run)||
     !identical(tolower(as.character(state$original_w08_sha256)),sha))
     stop("No-candidate completion requires the unchanged original W08 source")
   state$stage<-"completed_without_supplemental"
 }else if(event=="completed"){
   if(!stage%in%c("completed_without_supplemental","supplemental_w01_started"))
      stop("Final publication requires validated completion state")
   if(stage=="supplemental_w01_started"&&
      identical(as.character(state$original_w08_run_id),w08_run))
      stop("Supplemental generation must publish under a new W08 run ID")
   state$stage<-"completed"
   state$final_w08_run_id<-w08_run
   state$final_w08_sha256<-sha
 }
}
dir.create(dirname(marker),recursive=TRUE,showWarnings=FALSE)
writeLines(toJSON(state,auto_unbox=TRUE,pretty=TRUE,null="null"),marker)
cat("PASS: W08b routing state now ",state$stage," for ",update,"\n",sep="")
