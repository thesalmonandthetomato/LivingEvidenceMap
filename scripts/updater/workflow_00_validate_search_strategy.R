#!/usr/bin/env Rscript
# Offline, topic-agnostic Boolean syntax validation. Does not submit searches.
suppressPackageStartupMessages(library(jsonlite))
args<-commandArgs(trailingOnly=TRUE)
arg<-function(flag,default=NULL){i<-match(flag,args);if(is.na(i))return(default);if(i==length(args))stop(paste("Missing",flag),call.=FALSE);args[[i+1L]]}
path<-arg("--config")
if(is.null(path)||!file.exists(path))stop("W00 validation: --config must name an existing strategy file",call.=FALSE)
cfg<-fromJSON(path,simplifyVector=FALSE)
validate_expression<-function(x,label){
  if(!is.character(x)||length(x)!=1L||!nzchar(trimws(x)))stop(sprintf("%s: empty search expression",label),call.=FALSE)
  depth<-0L;quote<-FALSE;escaped<-FALSE
  chars<-strsplit(x,"",fixed=TRUE)[[1]]
  for(i in seq_along(chars)){
    c<-chars[[i]]
    if(escaped){escaped<-FALSE;next}
    if(identical(c,"\\") && quote){escaped<-TRUE;next}
    if(c=='"'){quote<-!quote;next}
    if(quote)next
    if(c=="(")depth<-depth+1L
    if(c==")"){depth<-depth-1L;if(depth<0L)stop(sprintf("%s: unmatched ')' at character %d",label,i),call.=FALSE)}
  }
  if(quote)stop(sprintf("%s: unmatched double quote",label),call.=FALSE)
  if(depth!=0L)stop(sprintf("%s: %d unmatched opening parenthesis(es)",label,depth),call.=FALSE)
  TRUE
}
if(!is.null(cfg$expression)){
  validate_expression(cfg$expression,"expression")
  if(is.null(cfg$concepts)||!length(cfg$concepts))stop("Concept-mode strategy must define named concepts",call.=FALSE)
  for(name in names(cfg$concepts)){
    terms<-cfg$concepts[[name]]$terms
    if(is.null(terms)||!length(terms))stop(sprintf("Concept '%s' has no terms",name),call.=FALSE)
    for(term in unlist(terms,use.names=FALSE))validate_expression(term,paste0("concept ",name))
  }
} else if(!is.null(cfg$advanced_boolean)) {
  validate_expression(cfg$advanced_boolean,"advanced_boolean")
} else if(!is.null(cfg$species_terms) && !is.null(cfg$farm_terms)) {
  for(term in c(unlist(cfg$species_terms),unlist(cfg$farm_terms)))validate_expression(term,"legacy search term")
} else stop("Strategy must provide concepts plus expression, advanced_boolean, or the existing legacy format",call.=FALSE)
if(!is.null(cfg$database_overrides))for(name in names(cfg$database_overrides))validate_expression(cfg$database_overrides[[name]],paste("override",name))
message(sprintf("W00 strategy syntax accepted: %s",path))
