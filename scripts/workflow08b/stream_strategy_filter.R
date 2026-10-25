#!/usr/bin/env Rscript
# W08b offline strategy verification, streaming candidate metadata without
# quadratic record accumulation. No W01 or production mutations.
suppressPackageStartupMessages(library(jsonlite))
`%||%`<-function(x,y)if(is.null(x))y else x
argv<-commandArgs(trailingOnly=TRUE)
if(length(argv)!=4L)stop("Usage: stream_strategy_filter.R metadata.jsonl strategy.json output.csv audit.json")
cfg<-fromJSON(argv[[2]],simplifyVector=FALSE)
if(!identical(cfg$search_version,"v2")||
   !all(c("maricultur*","aquacultur*")%in%unlist(cfg$farm_terms)))
 stop("Unexpected or incomplete strategy")
pattern<-function(term){
 if(grepl('^".*"$',term))return(paste0("\\b",gsub(" ","[[:space:]]+",substring(term,2,nchar(term)-1),fixed=TRUE),"\\b"))
 if(grepl("^[[:alnum:]]+\\*$",term))return(paste0("\\b",substr(term,1,nchar(term)-1),"[[:alnum:]]*\\b"))
 if(grepl("^[[:alnum:]]+$",term))return(paste0("\\b",term,"\\b"))
 stop("Unrecognised search term: ",term)
}
sp<-vapply(unlist(cfg$species_terms),pattern,character(1))
fp<-vapply(unlist(cfg$farm_terms),pattern,character(1))
src<-file(argv[[1]],"rt");on.exit(close(src),add=TRUE)
dst<-file(argv[[3]],"wt");on.exit(close(dst),add=TRUE)
writeLines("candidate_key,status,species_term_match,farm_term_match,metadata_complete,strategy_version",dst)
seen<-new.env(hash=TRUE,parent=emptyenv())
counts<-c(original_strategy_match=0L,not_matched=0L,metadata_incomplete=0L)
total<-0L
repeat{
 lines<-readLines(src,n=2000L,warn=FALSE)
 if(!length(lines))break
 results<-character(length(lines));n<-0L
 for(line in lines){
  if(!nzchar(trimws(line)))next
  z<-fromJSON(line,simplifyVector=FALSE)
  id<-as.character(z$candidate_key)
  if(length(id)!=1L||!nzchar(id)||exists(id,seen,inherits=FALSE))stop("Duplicate or missing candidate key")
  assign(id,TRUE,seen)
  val<-paste(as.character(z$title %||% ""),as.character(z$abstract %||% ""),
    paste(unlist(z$keywords %||% character()),collapse=" "))
  complete<-!is.null(z$title)&&!is.null(z$abstract)&&!is.null(z$keywords)
  sm<-any(vapply(sp,function(p)grepl(p,val,perl=TRUE,ignore.case=TRUE),logical(1)))
  fm<-any(vapply(fp,function(p)grepl(p,val,perl=TRUE,ignore.case=TRUE),logical(1)))
  status<-if(!complete)"metadata_incomplete" else if(sm&&fm)"original_strategy_match" else "not_matched"
  counts[[status]]<-counts[[status]]+1L;total<-total+1L;n<-n+1L
  results[[n]]<-paste(id,status,tolower(as.character(sm)),tolower(as.character(fm)),
   tolower(as.character(complete)),"v2",sep=",")
 }
 if(n)writeLines(results[seq_len(n)],dst)
}
info<-list(schema="workflow08b-strategy-filter-stream-v1",search_version="v2",
 candidates=total,matched=unname(counts[["original_strategy_match"]]),
 unknown=unname(counts[["metadata_incomplete"]]),not_matched=unname(counts[["not_matched"]]),
 w01_handoff_authorised=FALSE)
writeLines(toJSON(info,pretty=TRUE,auto_unbox=TRUE),argv[[4]])
cat("PASS: offline strategy classifications=",total,"; matched=",counts[["original_strategy_match"]],
 "; unknown=",counts[["metadata_incomplete"]],"; not_matched=",counts[["not_matched"]],"\\n",sep="")
