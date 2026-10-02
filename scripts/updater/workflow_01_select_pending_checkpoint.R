#!/usr/bin/env Rscript

suppressPackageStartupMessages(library(jsonlite))

args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag,default=NULL){
  i <- match(flag,args)
  if(is.na(i)) return(default)
  if(i==length(args)) stop(sprintf("Missing value after %s",flag),call.=FALSE)
  args[[i+1L]]
}

checkpoint_dir <- arg("--checkpoint-dir","docs/deduplication/checkpoints")
resolution_dir <- arg("--resolution-dir",file.path(checkpoint_dir,"resolutions"))
output <- arg("--output")
if(is.null(output)) stop("Required: --output",call.=FALSE)

paths <- list.files(checkpoint_dir,pattern="^run-[0-9]+\\.json$",full.names=TRUE)
rows <- list()
for(path in paths){
  x <- fromJSON(path,simplifyVector=FALSE)
  if(!identical(as.character(x$status),"published")) next
  if(!identical(as.character(x$state),"pre_adjudication")) next
  if(!identical(as.character(x$visibility),"restricted")) next
  run_id <- as.character(x$github_run_id)
  if(!grepl("^[0-9]+$",run_id)) stop("Checkpoint has invalid github_run_id: ",path,call.=FALSE)
  resolution <- file.path(resolution_dir,paste0("run-",run_id,".json"))
  if(file.exists(resolution)){
    r <- fromJSON(resolution,simplifyVector=FALSE)
    if(identical(as.character(r$status),"resolved")) next
  }
  rows[[length(rows)+1L]] <- list(
    pointer_path=gsub("\\\\","/",path),
    checkpoint_run_id=run_id,
    queue_sha256=tolower(as.character(x$queue_sha256)),
    pending_human_cases=as.integer(x$pending_human_cases),
    zenodo_record_id=as.character(x$zenodo_record_id)
  )
}

if(length(rows)>1L){
  ids <- vapply(rows,function(z)z$checkpoint_run_id,character(1))
  stop("Multiple unresolved W01 checkpoints found; refusing to guess: ",paste(ids,collapse=", "),call.=FALSE)
}

out <- if(!length(rows)) {
  list(schema="living-evidence-map-workflow01-pending-checkpoint-selection-v1",found=FALSE)
} else {
  c(list(schema="living-evidence-map-workflow01-pending-checkpoint-selection-v1",found=TRUE),rows[[1L]])
}
dir.create(dirname(output),recursive=TRUE,showWarnings=FALSE)
writeLines(toJSON(out,auto_unbox=TRUE,pretty=TRUE,null="null",na="null"),output,useBytes=TRUE)
cat(if(isTRUE(out$found)) paste0("FOUND ",out$checkpoint_run_id) else "NONE", "\n")
