#!/usr/bin/env Rscript
# Read-only W08b identity coverage audit. No API calls, writes only local outputs.
suppressPackageStartupMessages(library(jsonlite))
args <- commandArgs(trailingOnly=TRUE)
if(length(args)!=2L) stop("Usage: Rscript scripts/workflow08b/audit_identifiers.R <canonical.jsonl> <output_dir>")
input <- args[[1L]]; out <- args[[2L]]
if(!file.exists(input)) stop("Canonical JSONL absent")
dir.create(out,recursive=TRUE,showWarnings=FALSE)
scalar <- function(x) {
  if(is.null(x)||!length(x)) return("")
  z <- trimws(as.character(unlist(x,use.names=FALSE)[1L]))
  if(is.na(z)) "" else z
}
norm_doi <- function(x) {
  z <- tolower(scalar(x)); z <- sub("^https?://(dx\\.)?doi[.]org/","",z)
  z <- sub("^doi:[[:space:]]*","",z); z
}
norm_oa <- function(x) {
  z <- scalar(x); z <- sub("^https?://openalex[.]org/","",z,ignore.case=TRUE)
  z <- toupper(z); if(grepl("^W[0-9]+$",z)) z else ""
}
norm_lens <- function(x) scalar(x)
pick <- function(z) {
  z<-unique(z[nzchar(z)])
  if(length(z)==1L) z else if(length(z)==0L) "" else paste(z,collapse="|")
}
con <- file(input,"r",encoding="UTF-8");on.exit(close(con))
rows<-list(); i<-0L
repeat {
  lines<-readLines(con,n=500L,warn=FALSE); if(!length(lines)) break
  for(line in lines) {
    if(!nzchar(trimws(line))) next
    x<-fromJSON(line,simplifyVector=FALSE); mans<-x$manifestations
    missing_manifestations <- is.null(mans) || !length(mans)
    if(missing_manifestations) mans <- list()
    id<-scalar(x$identity$record_id)
    if(!nzchar(id)) stop("Blank record_id")
    sources<-vapply(mans,function(m)scalar(m$source),character(1))
    lens<-character(); oa<-character(); dois<-norm_doi(x$canonical$doi)
    for(m in mans){
      sid<-m$manifestation_metadata$source_identity
      ids<-m$manifestation_metadata$identifiers
      if(scalar(m$source)=="lens") lens<-c(lens,norm_lens(sid$lens_id),norm_lens(m$source_record_id))
      if(scalar(m$source)=="openalex") oa<-c(oa,norm_oa(sid$openalex_id),norm_oa(m$source_record_id))
      oa<-c(oa,norm_oa(ids$openalex_id))
      dois<-c(dois,norm_doi(m$doi))
    }
    lens<-pick(lens);oa<-pick(oa);doi<-pick(dois)
    ambiguous <- grepl("|",paste(lens,oa,doi),fixed=TRUE)
    provider<-if(ambiguous) "identity_conflict" else if(missing_manifestations) "manifestations_missing" else if(nzchar(lens)) "lens" else if(nzchar(oa)) "openalex" else if(nzchar(doi)) "lens_doi_lookup" else "unresolved"
    i<-i+1L
    rows[[i]]<-data.frame(record_id=id,lens_id=lens,openalex_id=oa,doi=doi,
                          preferred_route=provider,identifier_conflict=ambiguous,
                          manifestation_count=length(mans),manifestations_missing=missing_manifestations,stringsAsFactors=FALSE)
  }
}
if(!length(rows)) stop("Empty canonical")
df<-do.call(rbind,rows)
if(anyDuplicated(df$record_id)) stop("Duplicate W08 canonical record IDs")
write.csv(df,file.path(out,"seed_identifier_audit.csv"),row.names=FALSE,quote=TRUE)
routes<-as.list(table(factor(df$preferred_route,levels=c("lens","openalex","lens_doi_lookup","unresolved","identity_conflict","manifestations_missing"))))
names(routes)<-c("lens","openalex","lens_doi_lookup","unresolved","identity_conflict","manifestations_missing")
summary<-list(schema="workflow08b-identifier-audit-v1",records=nrow(df),
              routes=routes,ambiguous_identifiers=sum(df$identifier_conflict),
              missing_manifestation_records=sum(df$manifestations_missing),
              has_lens=sum(nzchar(df$lens_id)),has_openalex=sum(nzchar(df$openalex_id)),
              has_doi=sum(nzchar(df$doi)))
writeLines(toJSON(summary,auto_unbox=TRUE,pretty=TRUE),file.path(out,"summary.json"))
cat("PASS: W08b read-only identifier audit for",nrow(df),"records; ambiguous",summary$ambiguous_identifiers,"\n")
