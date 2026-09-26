#!/usr/bin/env Rscript
suppressPackageStartupMessages({library(jsonlite);library(digest)})
args<-commandArgs(trailingOnly=TRUE)
arg<-function(flag,default=NULL){i<-match(flag,args);if(is.na(i))return(default);if(i==length(args))stop(sprintf("Missing value after %s",flag),call.=FALSE);args[[i+1L]]}
canonical<-arg("--canonical");included<-arg("--included-ids");output<-arg("--output");expected<-as.integer(arg("--expected-records","19407"))
if(any(vapply(list(canonical,included,output),is.null,logical(1))))stop("Required: --canonical --included-ids --output",call.=FALSE)
`%||%`<-function(x,y)if(is.null(x))y else x
ids<-readLines(included,warn=FALSE,encoding="UTF-8");ids<-ids[nzchar(trimws(ids))]
if(length(ids)!=expected||anyDuplicated(ids))stop("Included ID set cardinality/uniqueness failed",call.=FALSE)
wanted<-setNames(rep(FALSE,length(ids)),ids);seen<-setNames(rep(FALSE,length(ids)),ids)
dir.create(dirname(output),recursive=TRUE,showWarnings=FALSE)
inp<-file(canonical,"rt",encoding="UTF-8");out<-file(output,"wt",encoding="UTF-8");on.exit({close(inp);close(out)},add=TRUE)
n<-0L
repeat{
 lines<-readLines(inp,n=500L,warn=FALSE);if(!length(lines))break
 for(line in lines){
  if(!nzchar(trimws(line)))next
  x<-fromJSON(line,simplifyVector=FALSE);id<-as.character(x$identity$record_id %||% "")
  if(id%in%ids){writeLines(line,out,useBytes=TRUE);seen[[id]]<-TRUE;n<-n+1L}
 }
}
missing<-names(seen)[!seen]
if(length(missing))stop(sprintf("%d included record_ids absent from canonical input",length(missing)),call.=FALSE)
if(n!=expected)stop(sprintf("Expected %d materialised records, wrote %d",expected,n),call.=FALSE)
cat(sprintf("PASS: materialised %d Workflow 04-retained canonical records; sha256=%s\n",n,digest(file=output,algo="sha256",serialize=FALSE)))
