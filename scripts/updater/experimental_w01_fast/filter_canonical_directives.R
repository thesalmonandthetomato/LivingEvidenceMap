#!/usr/bin/env Rscript
# Isolated filtering of existing abstract-strip and approved repair directives.
# Preserve verbatim JSONL and avoid row-index references.
suppressPackageStartupMessages({library(data.table);library(jsonlite);library(digest)})
args<-commandArgs(trailingOnly=TRUE)
`%||%`<-function(x,y)if(is.null(x)) y else x
arg<-function(k,required=TRUE){i<-match(k,args);if(is.na(i)){if(required)stop(paste("Missing",k));return(NULL)}
 if(i==length(args))stop(paste("Missing value",k));args[[i+1L]]}
map_path<-arg("--affected-cluster-map");out<-arg("--output-dir")
strips<-arg("--strip-actions",FALSE);repairs<-arg("--data-quality-repairs",FALSE)
if(dir.exists(out)||file.exists(out))stop("Refusing to overwrite output")
m<-fread(map_path,colClasses=list(character=c("source","source_record_id")))
if(!all(c("source","source_record_id")%in%names(m))||
 anyNA(m[,.(source,source_record_id)])||
 anyDuplicated(m[,.(source,source_record_id)]))stop("Invalid affected map identities")
key<-function(src,id)paste0(nchar(src,type="bytes"),":",src,nchar(id,type="bytes"),":",id)
wanted<-key(m$source,m$source_record_id)
dir.create(out,recursive=TRUE)
counts<-list()
for(item in list(list(label="strip_actions",path=strips),list(label="data_quality_repairs",path=repairs))){
 target<-file.path(out,paste0(item$label,".jsonl"))
 lines<-if(is.null(item$path))character()else readLines(item$path,warn=FALSE,encoding="UTF-8")
 lines<-lines[nzchar(trimws(lines))]
 keep<-logical(length(lines));selected_keys<-character()
 for(i in seq_along(lines)){
  record<-fromJSON(lines[[i]],simplifyVector=FALSE)
  src<-as.character(record$source %||% "")
  id<-as.character(record$source_record_id %||% "")
  if(length(src)!=1L||length(id)!=1L||!nzchar(src)||!nzchar(id))
   stop("Directive lacks immutable source identity")
  if(grepl("::",src,fixed=TRUE)||grepl("::",id,fixed=TRUE))
   stop("Legacy canonical identity delimiter ambiguity")
  k<-key(src,id)
  keep[[i]]<-k%in%wanted
  if(keep[[i]])selected_keys<-c(selected_keys,k)
 }
 writeLines(lines[keep],target,useBytes=TRUE)
 counts[[item$label]]<-list(original=length(lines),selected=sum(keep),
  selected_identity_count=length(unique(selected_keys)))
}
writeLines(toJSON(list(schema="w01-fast-filtered-canonical-directives-v1",
 counts=counts,affected_map_sha256=digest(file=map_path,algo="sha256"),
 production_publication_allowed=FALSE),auto_unbox=TRUE,pretty=TRUE),
 file.path(out,"directives_audit.json"))
cat("PASS: selected source-specific canonical directives by stable identity\n")
