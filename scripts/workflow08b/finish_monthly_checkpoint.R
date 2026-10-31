#!/usr/bin/env Rscript
# Commit the final W08 SHA to the already-accepted monthly discovery entry.
# Does not create or amend a provider checkpoint.
suppressPackageStartupMessages(library(jsonlite))
a<-commandArgs(trailingOnly=TRUE)
if(length(a)!=5L)stop("Usage: finish_monthly_checkpoint.R registry.json month final_w08_run final_w08_sha output.json")
`%||%`<-function(x,y)if(is.null(x)||!length(x))y else x
x<-fromJSON(a[[1]],simplifyVector=FALSE)
month<-a[[2]];run<-a[[3]];sha<-tolower(a[[4]])
if(!identical(x$schema,"workflow08b-monthly-checkpoint-registry-v1")||
 !grepl("^[0-9]{4}-(0[1-9]|1[0-2])$",month)||
 !grepl("^[0-9]+$",run)||!grepl("^[a-f0-9]{64}$",sha))stop("Invalid final monthly release")
idx<-which(vapply(x$checkpoints,function(z)identical(as.character(z$month),month),logical(1)))
if(length(idx)!=1L||!identical(x$checkpoints[[idx]]$status,"verified_archive"))
 stop("No accepted monthly discovery checkpoint")
z<-x$checkpoints[[idx]]
oldrun<-as.character(z$post_chasing_w08_source_run_id %||% "")
oldsha<-tolower(as.character(z$post_chasing_w08_sha256 %||% ""))
if(nzchar(oldrun)&&(!identical(oldrun,run)||!identical(oldsha,sha)))
 stop("Conflicting final W08 checksum; cannot overwrite")
z$post_chasing_w08_source_run_id<-run
z$post_chasing_w08_sha256<-sha
z$note<-"Discovery checkpoint and completed canonical publication checksum both accepted."
x$checkpoints[[idx]]<-z
dir.create(dirname(a[[5]]),recursive=TRUE,showWarnings=FALSE)
writeLines(toJSON(x,auto_unbox=TRUE,pretty=TRUE,null="null"),a[[5]])
cat("PASS: final month checksum accepted without changing discovery checkpoint\n")
