#!/usr/bin/env Rscript
# Offline source of truth for W00 dispatch. Refuses altered or absent archived queries.
suppressPackageStartupMessages({library(jsonlite);library(digest)})
args<-commandArgs(trailingOnly=TRUE)
arg<-function(flag,default=NULL){i<-match(flag,args);if(is.na(i))return(default);if(i==length(args))stop(sprintf("Missing %s",flag),call.=FALSE);args[[i+1L]]}
archive<-arg("--archive")
selection<-arg("--source-selection")
output<-arg("--output")
if(is.null(archive)||is.null(selection)||is.null(output))stop("W00: --archive, --source-selection and --output required",call.=FALSE)
manifest_path<-file.path(archive,"manifest.json")
if(!file.exists(manifest_path))stop(sprintf("W00: missing archive manifest: %s",manifest_path),call.=FALSE)
m<-fromJSON(manifest_path,simplifyVector=FALSE)
if(!identical(m$schema,"w00-query-archive-v1"))stop("W00: unsupported query archive schema",call.=FALSE)
sel<-unlist(fromJSON(selection,simplifyVector=FALSE)$selected_sources,use.names=FALSE)
if(!length(sel)||anyDuplicated(sel))stop("W00: source selection empty or duplicated",call.=FALSE)
missing<-setdiff(sel,names(m$queries))
if(length(missing))stop(sprintf("W00: archived query missing for selected source(s): %s",paste(missing,collapse=", ")),call.=FALSE)
queries<-setNames(lapply(sel,function(source){
  entry<-m$queries[[source]]
  path<-file.path(archive,entry$file)
  if(!identical(basename(path),paste0(source,".txt"))||!file.exists(path))stop(sprintf("W00: invalid archive query path for %s",source),call.=FALSE)
  hash<-digest(file=path,algo="sha256",serialize=FALSE)
  if(!identical(tolower(hash),tolower(entry$sha256)))stop(sprintf("W00: SHA-256 mismatch in archived %s query",source),call.=FALSE)
  q<-paste(readLines(path,warn=FALSE,encoding="UTF-8"),collapse="\n")
  if(!nzchar(trimws(q)))stop(sprintf("W00: empty archived query for %s",source),call.=FALSE)
  q
}),sel)
dir.create(dirname(output),recursive=TRUE,showWarnings=FALSE)
writeLines(toJSON(queries,auto_unbox=TRUE,pretty=TRUE,null="null"),output,useBytes=TRUE)
message(sprintf("W00: restored and verified %d queries from immutable run archive",length(queries)))
