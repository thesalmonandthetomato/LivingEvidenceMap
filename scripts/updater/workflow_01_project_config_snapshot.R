#!/usr/bin/env Rscript
# Snapshot optional project configuration inside the W01 Zenodo-bound archive.
# Never silently substitute changed files when resuming a checkpoint.
suppressPackageStartupMessages({library(jsonlite);library(digest)})
args<-commandArgs(trailingOnly=TRUE)
arg<-function(k,default=NULL){i<-match(k,args);if(is.na(i))return(default);if(i==length(args))stop(paste("Missing",k),call.=FALSE);args[[i+1L]]}
mode<-arg("--mode");archive<-arg("--archive-dir");input<-arg("--input-dir","user_input")
if(is.null(mode)||is.null(archive)||!(mode %in% c("snapshot","restore")))stop("Required: --mode snapshot|restore --archive-dir DIR",call.=FALSE)
names<-c("workflow01_manual_sources.json")
legacy_names<-c("workflow01_explicit_cluster_splits.json","workflow01_identifier_never_auto_resolve.csv")
dest<-file.path(archive,"project_configuration")
manifest_path<-file.path(dest,"manifest.json")
if(mode=="snapshot"){
  dir.create(dest,recursive=TRUE,showWarnings=FALSE)
  registry<-list()
  for(n in names){
    src<-file.path(input,n)
    if(!file.exists(src))next
    if(dir.exists(src))stop(paste("Configuration path is a directory:",src),call.=FALSE)
    if(!file.copy(src,file.path(dest,n),overwrite=TRUE))stop(paste("Cannot snapshot:",src),call.=FALSE)
    registry[[n]]<-list(sha256=digest(file=file.path(dest,n),algo="sha256",serialize=FALSE),
                        bytes=unname(file.info(file.path(dest,n))$size))
  }
  manifest<-list(schema="living-evidence-map-w01-project-config-v1",files=registry)
  writeLines(toJSON(manifest,auto_unbox=TRUE,pretty=TRUE,null="null"),manifest_path)
  cat("PASS: project configuration snapshotted with SHA256 checksums\n")
}else{
  if(!file.exists(manifest_path)){cat("Legacy checkpoint: no configuration snapshot; no changes made\n");quit(status=0L)}
  m<-fromJSON(manifest_path,simplifyVector=FALSE)
  if(!identical(m$schema,"living-evidence-map-w01-project-config-v1"))stop("Invalid configuration manifest",call.=FALSE)
  listed<-names(m$files)
  if(length(setdiff(listed,c(names,legacy_names))))stop("Unknown archived project configuration",call.=FALSE)
  for(n in listed){
    src<-file.path(dest,n);z<-m$files[[n]]
    if(!file.exists(src)||!identical(digest(file=src,algo="sha256",serialize=FALSE),z$sha256)||
       as.numeric(file.info(src)$size)!=as.numeric(z$bytes))stop(paste("Archived configuration integrity failure",n),call.=FALSE)
  }
  dir.create(input,recursive=TRUE,showWarnings=FALSE)
  for(n in names){
    target<-file.path(input,n)
    if(n %in% listed){
      if(!file.copy(file.path(dest,n),target,overwrite=TRUE))stop(paste("Cannot restore",n),call.=FALSE)
    }else if(file.exists(target))unlink(target)
  }
  for(n in legacy_names){
    target<-file.path(input,n)
    if(file.exists(target))unlink(target)
  }
  cat("PASS: restored supported project configuration; historical corrections excluded\n")
}
