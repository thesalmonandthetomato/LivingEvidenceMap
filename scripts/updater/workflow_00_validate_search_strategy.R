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
validate_concept_grammar <- function(expr,ids){
  tokens<-regmatches(expr,gregexpr("[A-Za-z][A-Za-z0-9_]*|[()]",expr,perl=TRUE))[[1]]
  remaining<-gsub("[A-Za-z][A-Za-z0-9_]*|[()]","",expr,perl=TRUE)
  if(nzchar(trimws(remaining)))stop("W00: invalid character(s) in named-concept expression",call.=FALSE)
  if(!length(tokens))stop("W00: empty named-concept expression",call.=FALSE)
  keywords<-c("AND","OR","NOT")
  for(t in tokens){
    if(t%in%c("(",")"))next
    if(toupper(t)%in%keywords && t!=toupper(t))stop(sprintf("W00: Boolean operator must be uppercase: %s",t),call.=FALSE)
    if(!t%in%keywords && !t%in%ids)stop(sprintf("W00: unknown concept identifier: %s",t),call.=FALSE)
  }
  pos<-1L
  peek<-function()if(pos<=length(tokens))tokens[[pos]] else ""
  consume<-function(){out<-peek();pos<<-pos+1L;out}
  parse_primary<-NULL;parse_not<-NULL;parse_and<-NULL;parse_or<-NULL
  parse_primary<-function(){
    t<-peek()
    if(t=="("){consume();parse_or();if(peek()!=")")stop("W00: expected ')' after expression",call.=FALSE);consume();return(invisible(NULL))}
    if(t%in%ids){consume();return(invisible(NULL))}
    stop(sprintf("W00: expected concept or '('; found '%s'",t),call.=FALSE)
  }
  parse_not<-function(){if(peek()=="NOT"){consume();parse_not()}else parse_primary()}
  parse_and<-function(){parse_not();while(peek()=="AND"){consume();parse_not()}}
  parse_or<-function(){parse_and();while(peek()=="OR"){consume();parse_and()}}
  parse_or()
  if(pos<=length(tokens))stop(sprintf("W00: unexpected token '%s' after expression",peek()),call.=FALSE)
  invisible(TRUE)
}
if(!is.null(cfg$expression)){
  validate_expression(cfg$expression,"expression")
  if(is.null(cfg$concepts)||!length(cfg$concepts)||is.null(names(cfg$concepts)))stop("Concept-mode strategy must define named concepts",call.=FALSE)
  ids<-names(cfg$concepts)
  if(any(!grepl("^[A-Za-z][A-Za-z0-9_]*$",ids))||any(toupper(ids)%in%c("AND","OR","NOT")))stop("W00: invalid or reserved concept name",call.=FALSE)
  validate_concept_grammar(cfg$expression,ids)
  for(name in ids){
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
