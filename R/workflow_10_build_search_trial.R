#!/usr/bin/env Rscript
suppressPackageStartupMessages({library(jsonlite);library(readr);library(digest)})

args <- commandArgs(trailingOnly=TRUE)
dashboard_js <- if(length(args)>=1L) args[[1L]] else stop("Missing Workflow 10 dashboard-data.js",call.=FALSE)
canonical_jsonl <- if(length(args)>=2L) args[[2L]] else stop("Missing authoritative Workflow 08 canonical JSONL",call.=FALSE)
out_data_js <- if(length(args)>=3L) args[[3L]] else "outputs/workflow10-search-trial/workflow10-search-trial-data.js"
out_index_js <- if(length(args)>=4L) args[[4L]] else "outputs/workflow10-search-trial/workflow10-search-trial-index.js"

stopf <- function(...) stop(sprintf(...),call.=FALSE)
if(!file.exists(dashboard_js)) stopf("Dashboard JS not found: %s",dashboard_js)
if(!file.exists(canonical_jsonl)) stopf("Canonical JSONL not found: %s",canonical_jsonl)

raw_js <- paste(readLines(dashboard_js,warn=FALSE,encoding="UTF-8"),collapse="\n")
prefix <- "window.LIVING_EVIDENCE_MAP_DASHBOARD_DATA="
if(!startsWith(raw_js,prefix)||!endsWith(raw_js,";")) stopf("Unexpected dashboard JS wrapper")
payload <- fromJSON(substr(raw_js,nchar(prefix)+1L,nchar(raw_js)-1L),simplifyVector=FALSE)
if(!is.list(payload$records)||!length(payload$records)) stopf("Dashboard payload has no records")

# Restore dashboard-only Level 1/2 topic definitions without changing the
# analytical ontology or any dashboard interaction logic.
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

# Every Level 1 and Level 2 path represented in the dashboard must now resolve
# to a definition. Level 3 definitions continue to come from the ontology.
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
if(canonical_n!=length(payload$records)) stopf("Canonical/dashboard record-count mismatch: %d vs %d",canonical_n,length(payload$records))

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

record_ids <- character(length(payload$records))
token_counts <- integer(length(payload$records))
postings <- new.env(parent=emptyenv(),hash=TRUE)

for(i in seq_along(payload$records)){
  r <- payload$records[[i]]
  rid <- as.character(r$record_id %||% "")
  if(!nzchar(rid)||!exists(rid,envir=canonical,inherits=FALSE)) stopf("Record %d missing from canonical JSONL: %s",i,rid)
  src <- get(rid,envir=canonical,inherits=FALSE)
  abstract <- normalise_ws(src$abstract)
  record_ids[[i]] <- rid

  # Public trial payload contains only a 30-word snippet, never the full abstract.
  r$abstract <- NULL
  r$abstract_snippet <- snippet30(abstract)
  r$issue <- normalise_ws(src$issue)
  payload$records[[i]] <- r

  if(!nzchar(abstract)){
    token_counts[[i]] <- 0L
    next
  }

  tokens <- strsplit(abstract," ",fixed=TRUE)[[1L]]
  token_counts[[i]] <- length(tokens)
  # Group positions by token within the record first. This preserves exact
  # 0-based token positions but avoids repeatedly copying a posting list
  # for every token occurrence.
  pos_by_token <- split(as.integer(seq_along(tokens)-1L),tokens)
  pos_by_token <- pos_by_token[nzchar(names(pos_by_token))]
  key <- as.character(i-1L)
  for(tok in names(pos_by_token)){
    by_record <- if(exists(tok,envir=postings,inherits=FALSE)) get(tok,envir=postings,inherits=FALSE) else list()
    by_record[[key]] <- pos_by_token[[tok]]
    assign(tok,by_record,envir=postings)
  }
}

token_keys <- sort(ls(postings,all.names=TRUE))
postings_list <- setNames(lapply(token_keys,function(k)get(k,envir=postings,inherits=FALSE)),token_keys)

index_payload <- list(
  schema="living-evidence-map-abstract-inverted-index-v1",
  position_unit="whitespace_token_0_based",
  normalisation="original token text; source whitespace collapsed to single spaces",
  record_ids=as.list(record_ids),
  token_counts=as.list(as.integer(token_counts)),
  postings=postings_list
)

dir.create(dirname(out_data_js),recursive=TRUE,showWarnings=FALSE)
writeLines(
  paste0("window.LIVING_EVIDENCE_MAP_DASHBOARD_DATA=",toJSON(payload,auto_unbox=TRUE,null="null",na="null",pretty=FALSE),";"),
  out_data_js,useBytes=TRUE
)
writeLines(
  paste0("window.LIVING_EVIDENCE_MAP_ABSTRACT_INDEX=",toJSON(index_payload,auto_unbox=TRUE,null="null",na="null",pretty=FALSE),";"),
  out_index_js,useBytes=TRUE
)

# Verify structurally that the public trial payload has no full abstract field
# and that every snippet is exactly the permitted first <=30 words.
for(i in seq_along(payload$records)){
  r <- payload$records[[i]]
  rid <- as.character(r$record_id %||% "")
  src <- get(rid,envir=canonical,inherits=FALSE)
  source_abstract <- normalise_ws(src$abstract)
  expected_snippet <- snippet30(source_abstract)

  if(!is.null(r[["abstract",exact=TRUE]])) stopf("Full abstract field survived in trial payload for record %s",rid)
  if(is.null(r$abstract_snippet)) stopf("Abstract snippet missing from trial payload for record %s",rid)
  if(!identical(as.character(r$abstract_snippet),expected_snippet)){
    stopf("Abstract snippet mismatch for record %s",rid)
  }

  snip_plain <- sub("…$","",as.character(r$abstract_snippet))
  snip_tokens <- if(nzchar(snip_plain)) strsplit(snip_plain," ",fixed=TRUE)[[1L]] else character()
  if(length(snip_tokens)>30L) stopf("Abstract snippet exceeds 30 words for record %s",rid)
}

manifest <- list(
  schema="living-evidence-map-workflow10-search-trial-v1",
  evidence_source="authoritative Workflow 08 canonical JSONL",
  canonical_jsonl_sha256=digest(file=canonical_jsonl,algo="sha256",serialize=FALSE),
  records=length(record_ids),
  records_with_abstract=sum(token_counts>0L),
  unique_abstract_tokens=length(token_keys),
  dashboard_data_sha256=digest(file=out_data_js,algo="sha256",serialize=FALSE),
  abstract_index_sha256=digest(file=out_index_js,algo="sha256",serialize=FALSE),
  dashboard_data_bytes=file.info(out_data_js)$size,
  abstract_index_bytes=file.info(out_index_js)$size
)
write_json(manifest,file.path(dirname(out_data_js),"search-trial-manifest.json"),auto_unbox=TRUE,pretty=TRUE)

cat(sprintf(
  "PASS: search trial built: %d records; %d with abstracts; %d unique abstract tokens; data %.1f MB; index %.1f MB\n",
  manifest$records,manifest$records_with_abstract,manifest$unique_abstract_tokens,
  manifest$dashboard_data_bytes/1024^2,manifest$abstract_index_bytes/1024^2
))
