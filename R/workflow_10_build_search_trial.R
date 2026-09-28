#!/usr/bin/env Rscript
suppressPackageStartupMessages({library(jsonlite);library(readr);library(digest)})

args <- commandArgs(trailingOnly=TRUE)
dashboard_js <- if(length(args)>=1L) args[[1L]] else stop("Missing Workflow 10 dashboard-data.js",call.=FALSE)
dashboard_csv <- if(length(args)>=2L) args[[2L]] else stop("Missing Workflow 10 living_evidence_map.csv",call.=FALSE)
out_data_js <- if(length(args)>=3L) args[[3L]] else "outputs/workflow10-search-trial/workflow10-search-trial-data.js"
out_index_js <- if(length(args)>=4L) args[[4L]] else "outputs/workflow10-search-trial/workflow10-search-trial-index.js"

stopf <- function(...) stop(sprintf(...),call.=FALSE)
if(!file.exists(dashboard_js)) stopf("Dashboard JS not found: %s",dashboard_js)
if(!file.exists(dashboard_csv)) stopf("Dashboard CSV not found: %s",dashboard_csv)

raw_js <- paste(readLines(dashboard_js,warn=FALSE,encoding="UTF-8"),collapse="\n")
prefix <- "window.LIVING_EVIDENCE_MAP_DASHBOARD_DATA="
if(!startsWith(raw_js,prefix)||!endsWith(raw_js,";")) stopf("Unexpected dashboard JS wrapper")
payload <- fromJSON(substr(raw_js,nchar(prefix)+1L,nchar(raw_js)-1L),simplifyVector=FALSE)
if(!is.list(payload$records)||!length(payload$records)) stopf("Dashboard payload has no records")

csv <- read_csv(dashboard_csv,show_col_types=FALSE,progress=FALSE)
req <- c("record_id","abstract","issue")
miss <- setdiff(req,names(csv))
if(length(miss)) stopf("Dashboard CSV missing columns: %s",paste(miss,collapse=", "))
if(nrow(csv)!=length(payload$records)) stopf("CSV/JS record-count mismatch: %d vs %d",nrow(csv),length(payload$records))
if(anyDuplicated(csv$record_id)) stopf("Dashboard CSV contains duplicate record_id")

csv_i <- setNames(seq_len(nrow(csv)),as.character(csv$record_id))

normalise_ws <- function(x){
  x <- as.character(x %||% "")
  x[is.na(x)] <- ""
  trimws(gsub("[[:space:]]+"," ",x,perl=TRUE))
}
`%||%` <- function(x,y) if(is.null(x)||length(x)==0L)y else x

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
  if(!nzchar(rid)||is.na(csv_i[[rid]])) stopf("Record %d missing from CSV: %s",i,rid)
  j <- csv_i[[rid]]
  abstract <- normalise_ws(csv$abstract[[j]])
  record_ids[[i]] <- rid

  # Public trial payload contains only a 30-word snippet, never the full abstract.
  r$abstract <- NULL
  r$abstract_snippet <- snippet30(abstract)
  r$issue <- if(is.na(csv$issue[[j]])) "" else as.character(csv$issue[[j]])
  payload$records[[i]] <- r

  if(!nzchar(abstract)){
    token_counts[[i]] <- 0L
    next
  }

  tokens <- strsplit(abstract," ",fixed=TRUE)[[1L]]
  token_counts[[i]] <- length(tokens)
  # 0-based token positions, matching the OpenAlex-style representation.
  for(pos0 in seq_along(tokens)-1L){
    tok <- tokens[[pos0+1L]]
    if(!nzchar(tok)) next
    by_record <- if(exists(tok,envir=postings,inherits=FALSE)) get(tok,envir=postings,inherits=FALSE) else list()
    key <- as.character(i-1L)
    by_record[[key]] <- c(by_record[[key]] %||% integer(),as.integer(pos0))
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

# Verify that no full abstract survived in the public trial dashboard payload.
trial_js <- paste(readLines(out_data_js,warn=FALSE,encoding="UTF-8"),collapse="\n")
for(i in seq_len(min(100L,nrow(csv)))){
  a <- normalise_ws(csv$abstract[[i]])
  if(nchar(a)>=120L && grepl(substr(a,1L,min(180L,nchar(a))),trial_js,fixed=TRUE)){
    stopf("Full abstract text leaked into trial dashboard payload for record %s",csv$record_id[[i]])
  }
}

manifest <- list(
  schema="living-evidence-map-workflow10-search-trial-v1",
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
