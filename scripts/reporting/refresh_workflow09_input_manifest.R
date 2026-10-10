#!/usr/bin/env Rscript
suppressPackageStartupMessages({library(jsonlite); library(digest)})
args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag,default=NULL){i<-match(flag,args);if(is.na(i))return(default);if(i==length(args))stop("Missing value after ",flag,call.=FALSE);args[[i+1L]]}
root <- arg("--input-dir","docs/reporting/workflow_09_inputs/current")
out <- arg("--output",file.path(root,"manifest.json"))
if(!dir.exists(root)) stop("Input directory not found: ",root,call.=FALSE)
files <- sort(list.files(root, full.names=TRUE))
files <- files[file.info(files)$isdir == FALSE]
files <- files[basename(files)!="manifest.json"]
entries <- lapply(files,function(p){
  rel <- basename(p)
  list(
    file=rel,
    bytes=as.numeric(file.info(p)$size),
    sha256=digest(file=p,algo="sha256",serialize=FALSE)
  )
})
summary_files <- files[grepl("^w0[0-8]_summary\\.json$",basename(files))]
stages <- lapply(summary_files,function(p){
  x<-fromJSON(p,simplifyVector=FALSE)
  list(stage=as.character(x$stage),source_run_id=as.character(x$source_run_id),file=basename(p))
})
if(length(stages)) stages <- stages[order(vapply(stages,function(x)x$stage,character(1)))]
payload <- list(
  schema="living-evidence-map-workflow09-input-manifest-v1",
  generated_at_utc=format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ"),
  stages=stages,
  files=entries
)
writeLines(toJSON(payload,auto_unbox=TRUE,pretty=TRUE,null="null"),out,useBytes=TRUE)
cat(sprintf("PASS: wrote Workflow 09 input manifest with %d files\n",length(entries)))
