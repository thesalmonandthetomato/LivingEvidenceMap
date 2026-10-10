#!/usr/bin/env Rscript
suppressPackageStartupMessages({library(jsonlite);library(digest)})

args <- commandArgs(trailingOnly=TRUE)
dashboard_js <- if(length(args)>=1L) args[[1L]] else stop("Missing internal dashboard JS path",call.=FALSE)
canonical_jsonl <- if(length(args)>=2L) args[[2L]] else stop("Missing authoritative Workflow 08 canonical JSONL",call.=FALSE)
out_data_js <- if(length(args)>=3L) args[[3L]] else stop("Missing public dashboard JS path",call.=FALSE)

stopf <- function(...) stop(sprintf(...),call.=FALSE)
if(!file.exists(dashboard_js)) stopf("Dashboard JS not found: %s",dashboard_js)
if(!file.exists(canonical_jsonl)) stopf("Canonical JSONL not found: %s",canonical_jsonl)

raw_js <- paste(readLines(dashboard_js,warn=FALSE,encoding="UTF-8"),collapse="\n")
prefix <- "window.LIVING_EVIDENCE_MAP_DASHBOARD_DATA="
if(!startsWith(raw_js,prefix)||!endsWith(raw_js,";")) stopf("Unexpected dashboard JS wrapper")
payload <- fromJSON(substr(raw_js,nchar(prefix)+1L,nchar(raw_js)-1L),simplifyVector=FALSE)
if(!is.list(payload$records)||!length(payload$records)) stopf("Dashboard payload has no records")

# This is deliberately the same public table projection used by the preserved
# Workflow 10 search-trial implementation, except that no abstract index or
# RIS/search artefact is built.
parent_definitions_path <- Sys.getenv("DASHBOARD_TOPIC_DEFINITIONS_PATH","docs/dashboard-topic-definitions.json")
if(!file.exists(parent_definitions_path)) stopf("Dashboard parent-topic definitions not found: %s",parent_definitions_path)
parent_definitions <- fromJSON(parent_definitions_path,simplifyVector=TRUE)
if(is.null(names(parent_definitions))||!length(parent_definitions)) stopf("Dashboard parent-topic definitions are empty or unnamed")
defs <- if(is.null(payload$topic_definitions)) list() else payload$topic_definitions
for(nm in names(parent_definitions)){
  value <- if(is.null(parent_definitions[[nm]])) "" else as.character(parent_definitions[[nm]])
  if(!nzchar(trimws(value))) stopf("Empty dashboard topic definition for: %s",nm)
  defs[[nm]] <- value
}
payload$topic_definitions <- defs

parent_paths <- character()
for(r in payload$records){
  for(p in (if(is.null(r$topic_paths)) list() else r$topic_paths)){
    parts <- as.character(unlist(p,use.names=FALSE))
    parts <- trimws(parts[nzchar(trimws(parts))])
    if(length(parts)>=1L) parent_paths <- c(parent_paths,parts[[1L]])
    if(length(parts)>=2L) parent_paths <- c(parent_paths,paste(parts[1:2],collapse=" > "))
  }
}
parent_paths <- sort(unique(parent_paths))
missing_parent_defs <- parent_paths[!vapply(parent_paths,function(x){
  z <- payload$topic_definitions[[x]]
  !is.null(z) && nzchar(trimws(as.character(if(length(z)) z[[1L]] else "")))
},logical(1))]
if(length(missing_parent_defs)) stopf(
  "Missing dashboard Level 1/2 topic definitions: %s",
  paste(missing_parent_defs,collapse="; ")
)

`%||%` <- function(x,y) if(is.null(x)||length(x)==0L)y else x
canonical <- new.env(parent=emptyenv(),hash=TRUE)
con <- file(canonical_jsonl,"rt",encoding="UTF-8")
on.exit(close(con),add=TRUE)
canonical_n <- 0L
repeat{
  lines <- readLines(con,n=500L,warn=FALSE)
  if(!length(lines)) break
  for(line in lines){
    if(!nzchar(trimws(line))) next
    rec <- fromJSON(line,simplifyVector=FALSE)
    rid <- as.character(((rec$identity %||% list())$record_id) %||% "")
    if(!nzchar(rid)) stopf("Canonical record without record_id")
    if(exists(rid,envir=canonical,inherits=FALSE)) stopf("Duplicate canonical record_id: %s",rid)
    if(!isTRUE((rec$screening %||% list())$final_included)) stopf("Canonical JSONL contains non-included record: %s",rid)
    can <- rec$canonical %||% list()
    assign(rid,list(
      abstract=as.character(can$abstract %||% ""),
      issue=as.character(can$issue %||% "")
    ),envir=canonical)
    canonical_n <- canonical_n+1L
  }
}
close(con);on.exit(NULL,add=FALSE)
if(canonical_n!=length(payload$records)) stopf(
  "Canonical/dashboard record-count mismatch: %d vs %d",
  canonical_n,length(payload$records)
)

normalise_ws <- function(x){
  x <- as.character(x %||% "")
  x[is.na(x)] <- ""
  trimws(gsub("[[:space:]]+"," ",x,perl=TRUE))
}
snippet30 <- function(x){
  x <- normalise_ws(x)
  if(!nzchar(x)) return("")
  tok <- strsplit(x," ",fixed=TRUE)[[1L]]
  if(length(tok)<=30L) return(x)
  paste0(paste(tok[seq_len(30L)],collapse=" "),"…")
}

for(i in seq_along(payload$records)){
  r <- payload$records[[i]]
  rid <- as.character(r$record_id %||% "")
  if(!nzchar(rid)||!exists(rid,envir=canonical,inherits=FALSE)) {
    stopf("Record %d missing from canonical JSONL: %s",i,rid)
  }
  src <- get(rid,envir=canonical,inherits=FALSE)
  r$abstract <- NULL
  r$abstract_snippet <- snippet30(src$abstract)
  r$issue <- normalise_ws(src$issue)
  payload$records[[i]] <- r
}

payload$public_projection <- list(
  schema="living-evidence-map-workflow10-public-dashboard-table-v1",
  database_table=TRUE,
  full_abstracts=FALSE,
  abstract_snippet_words=30L,
  search=FALSE,
  ris_download=FALSE,
  abstract_index=FALSE
)

dir.create(dirname(out_data_js),recursive=TRUE,showWarnings=FALSE)
writeLines(
  paste0(prefix,toJSON(payload,auto_unbox=TRUE,null="null",na="null",pretty=FALSE),";"),
  out_data_js,useBytes=TRUE
)

# Structural verification: preserve the original public database table fields,
# but never expose the full abstract.
for(i in seq_along(payload$records)){
  r <- payload$records[[i]]
  rid <- as.character(r$record_id %||% "")
  src <- get(rid,envir=canonical,inherits=FALSE)
  expected_snippet <- snippet30(src$abstract)
  if(!is.null(r[["abstract",exact=TRUE]])) stopf("Full abstract field survived in public payload for record %s",rid)
  if(is.null(r$abstract_snippet)) stopf("Abstract snippet missing from public payload for record %s",rid)
  if(!identical(as.character(r$abstract_snippet),expected_snippet)) stopf("Abstract snippet mismatch for record %s",rid)
  snip_plain <- sub("…$","",as.character(r$abstract_snippet))
  snip_tokens <- if(nzchar(snip_plain)) strsplit(snip_plain," ",fixed=TRUE)[[1L]] else character()
  if(length(snip_tokens)>30L) stopf("Abstract snippet exceeds 30 words for record %s",rid)
}
required_table_fields <- c(
  "record_id","title","abstract_snippet","doi","year","authors","journal",
  "volume","pages","species","countries","iso3","topics","topic_paths",
  "topic_stars"
)
missing_fields <- unique(unlist(lapply(payload$records,function(r)setdiff(required_table_fields,names(r))),use.names=FALSE))
if(length(missing_fields)) stopf("Public table payload is missing required field(s): %s",paste(missing_fields,collapse=", "))

cat(sprintf(
  "PASS: public W10 table projection contains %d records; no full abstracts/search index/RIS artefact; SHA-256 %s\n",
  length(payload$records),digest(file=out_data_js,algo="sha256",serialize=FALSE)
))
