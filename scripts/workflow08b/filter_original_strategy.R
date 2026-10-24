#!/usr/bin/env Rscript
# Fail-closed candidate-side original-strategy exclusion.
# This is a local verification layer, NOT a substitute for provider-side NOT
# filtering. Required metadata: title, abstract, keywords, DOI, Lens/OpenAlex ID.
suppressPackageStartupMessages(library(jsonlite))
`%||%`<-function(x,y)if(is.null(x))y else x
a<-commandArgs(trailingOnly=TRUE)
if(length(a)!=4L)stop("Usage: filter_original_strategy.R candidates.jsonl strategy.json output.csv audit.json")
cfg<-fromJSON(a[[2]],simplifyVector=FALSE)
if(!identical(as.character(cfg$search_version),"v2"))stop("Unexpected strategy revision")
species<-unlist(cfg$species_terms,use.names=FALSE)
farm<-unlist(cfg$farm_terms,use.names=FALSE)
if(!all(c("maricultur*","aquacultur*")%in%farm))stop("Incomplete registered strategy")
# No regex heuristics: translate only known plain, wildcard suffix or
# exact-phrase syntax, then test against case-normalised metadata.
pattern<-function(term){
 if(grepl('^".*"$',term))return(paste0("\\b",gsub(" ","[[:space:]]+",substring(term,2,nchar(term)-1),fixed=TRUE),"\\b"))
 if(grepl("^[[:alnum:]]+\\*$",term))return(paste0("\\b",substr(term,1,nchar(term)-1),"[[:alnum:]]*\\b"))
 if(grepl("^[[:alnum:]]+$",term))return(paste0("\\b",term,"\\b"))
 stop("Unrecognised search term syntax: ",term)
}
sp<-vapply(species,pattern,character(1));fp<-vapply(farm,pattern,character(1))
lines<-readLines(a[[1]],warn=FALSE)
ids<-character();results<-list();n<-0L
for(line in lines){
 if(!nzchar(trimws(line)))next
 x<-fromJSON(line,simplifyVector=FALSE)
 id<-as.character(x$candidate_key %||% "")
 if(!nzchar(id)||id%in%ids)stop("Duplicate or missing candidate key")
 ids<-c(ids,id)
 text<-paste(as.character(x$title %||% ""),as.character(x$abstract %||% ""),
  paste(unlist(x$keywords %||% character(),use.names=FALSE),collapse=" "))
 # Absent fields must be tracked, not silently interpreted as searchable absence.
 complete<-!is.null(x$title) && !is.null(x$abstract) && !is.null(x$keywords)
 s_match<-any(vapply(sp,grepl,logical(1),x=tolower(text),perl=TRUE,ignore.case=TRUE))
 f_match<-any(vapply(fp,grepl,logical(1),x=tolower(text),perl=TRUE,ignore.case=TRUE))
 status<-if(!complete)"metadata_incomplete" else if(s_match&&f_match)"original_strategy_match" else "not_matched"
 n<-n+1L;results[[n]]<-data.frame(candidate_key=id,status=status,
  species_term_match=s_match,farm_term_match=f_match,metadata_complete=complete,
  strategy_version="v2",stringsAsFactors=FALSE)
}
df<-if(length(results))do.call(rbind,results)else data.frame(candidate_key=character(),status=character(),
 species_term_match=logical(),farm_term_match=logical(),metadata_complete=logical(),strategy_version=character())
write.csv(df,a[[3]],row.names=FALSE)
info<-list(schema="workflow08b-strategy-filter-v1",search_version="v2",candidates=nrow(df),
 matched=sum(df$status=="original_strategy_match"),unknown=sum(df$status=="metadata_incomplete"),
 eligible_for_identity_check=sum(df$status=="not_matched"),w01_handoff_authorised=FALSE)
writeLines(toJSON(info,pretty=TRUE,auto_unbox=TRUE),a[[4]])
cat("PASS: strategy screen recorded ",nrow(df)," candidates; no W01 handoff authorised\n",sep="")
`%||%`<-function(x,y)if(is.null(x))y else x
