#!/usr/bin/env Rscript
# Safe W08 publication router. Until the controlled activation marker is active,
# preserve the existing direct W08→W09 behaviour unchanged.
suppressPackageStartupMessages(library(jsonlite))
a<-commandArgs(trailingOnly=TRUE)
if(length(a)!=3L)stop("Usage: check_activation.R current_status.json activation.json output.json")
status<-fromJSON(a[[1]],simplifyVector=FALSE)
config<-fromJSON(a[[2]],simplifyVector=FALSE)
if(!identical(as.character(config$schema),"workflow08b-monthly-activation-v1"))
  stop("Invalid W08b activation configuration")
if(!identical(as.character(config$branch),"workflow01-final-architecture")||
   !identical(as.character(status$branch),"workflow01-final-architecture"))
  stop("W08b activation is only allowed on workflow01-final-architecture")
mode<-as.character(config$mode)
if(!mode%in%c("staged","active"))stop("Unsupported activation mode")
enabled<-identical(mode,"active")&&isTRUE(config$automatically_route_w08)&&
  isTRUE(config$automatically_run_provider_queries)
if(identical(mode,"active")&&!enabled)
  stop("Active flag without both safeguards explicitly enabled")
month<-substr(as.character(status$search$search_date),1L,7L)
if(!grepl("^[0-9]{4}-(0[1-9]|1[0-2])$",month))stop("Invalid current search month")
minimum<-as.character(config$earliest_update_month)
if(!grepl("^[0-9]{4}-(0[1-9]|1[0-2])$",minimum))stop("Invalid W08b activation month")
if(enabled&&month>=minimum){
  run<-as.character(status$workflow_runs$W08)
  if(!grepl("^[0-9]+$",run))stop("Missing authoritative W08 run for W08b dispatcher")
  next_stage<-"w08b_monthly_dispatch"
}else next_stage<-"existing_w09"
result<-list(schema="workflow08b-activation-decision-v1",
  mode=mode,update_month=month,route=next_stage,
  existing_w09_route_preserved=identical(next_stage,"existing_w09"),
  provider_execution_requested=enabled&&month>=minimum,
  generation_not_inferred=TRUE)
dir.create(dirname(a[[3]]),recursive=TRUE,showWarnings=FALSE)
writeLines(toJSON(result,pretty=TRUE,auto_unbox=TRUE),a[[3]])
cat("PASS: W08 activation route: ",next_stage,"\n",sep="")
