#!/usr/bin/env Rscript
suppressPackageStartupMessages(library(jsonlite))
args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag,default=NULL){i<-match(flag,args);if(is.na(i))return(default);if(i==length(args))stop(paste("Missing",flag));args[[i+1L]]}
root <- arg("--root"); out <- arg("--output")
if(is.null(root)||is.null(out)) stop("Required: --root --output",call.=FALSE)
scalar <- function(x){if(is.null(x)||!length(x))return(NULL);y<-trimws(as.character(x[[1L]]));if(!nzchar(y))NULL else y}
kind <- function(r){
  if(is.list(r$lens)) return("lens")
  p <- scalar((r$source %||% list())$provider)
  if(identical(p,"scopus")) return("scopus")
  if(identical(p,"openalex")) return("openalex")
  if(identical(p,"agricola_via_europe_pmc")) return("agricola")
  if(identical(p,"wos_starter")) return("wos")
  NULL
}
`%||%` <- function(x,y) if(is.null(x)) y else x
files <- list.files(root,pattern="\\.jsonl$",recursive=TRUE,full.names=TRUE)
cand <- list()
for(p in files){
  con <- file(p,"rt",encoding="UTF-8")
  first <- ""
  repeat{
    z <- readLines(con,n=1L,warn=FALSE)
    if(!length(z)) break
    if(nzchar(trimws(z))){first<-z;break}
  }
  close(con)
  if(!nzchar(first)) next
  r <- tryCatch(fromJSON(first,simplifyVector=FALSE),error=function(e)NULL)
  if(is.null(r)) next
  src <- tryCatch(kind(r),error=function(e)NULL)
  if(is.null(src)) next
  n <- length(readLines(p,warn=FALSE,encoding="UTF-8"))
  cand[[length(cand)+1L]] <- data.frame(source=src,path=normalizePath(p),lines=n,stringsAsFactors=FALSE)
}
if(!length(cand)) stop("No source-record JSONL files detected",call.=FALSE)
d <- do.call(rbind,cand)
wanted <- c("lens","scopus","openalex","agricola","wos")
sel <- lapply(wanted,function(src){
  x <- d[d$source==src,,drop=FALSE]
  if(!nrow(x)) stop(sprintf("No restored JSONL detected for %s",src),call.=FALSE)
  x <- x[order(-x$lines,x$path),,drop=FALSE]
  x[1,,drop=FALSE]
})
s <- do.call(rbind,sel)
names_out <- setNames(as.list(s$path),s$source)
counts <- setNames(as.list(as.integer(s$lines)),s$source)
dir.create(dirname(out),recursive=TRUE,showWarnings=FALSE)
writeLines(toJSON(list(files=names_out,line_counts=counts),auto_unbox=TRUE,pretty=TRUE),out,useBytes=TRUE)
cat(sprintf("PASS: located five restored source JSONLs (%s)\n",paste(sprintf("%s=%d",s$source,s$lines),collapse=", ")))
