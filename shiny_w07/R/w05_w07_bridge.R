# Shiny execution pathway only. Read-only W05 to W07 topic input bridge.
# No W06 dependencies, model calls, publication, or production state writes.
w07_bridge_sha <- function(x) digest::digest(x,algo="sha256",serialize=FALSE)
w07_bridge_records <- function(input_bytes,manifest) {
  if(!identical(as.character(manifest$mode),"full_corpus") ||
     !identical(as.character(manifest$schema),"lem-w05-crop-test-v1") ||
     !identical(as.character(manifest$input_sha256),w07_bridge_sha(input_bytes)))
    stop("Published W05 input manifest integrity failure",call.=FALSE)
  expected <- suppressWarnings(as.integer(manifest$input_records))
  processed <- suppressWarnings(as.integer(manifest$processed_records))
  if(length(expected)!=1L || is.na(expected) || expected<1L ||
     length(processed)!=1L || is.na(processed) || processed!=expected)
    stop("W05 full-corpus completeness failure",call.=FALSE)
  lines <- strsplit(rawToChar(input_bytes),"\n",fixed=TRUE)[[1L]]
  lines <- lines[nzchar(trimws(lines))]
  if(length(lines)!=expected)stop("W05 JSONL record count mismatch",call.=FALSE)
  scalar <- function(x) {
    if(is.null(x)||length(x)!=1L||is.list(x)||is.na(x)) return("")
    as.character(x)
  }
  rows <- lapply(lines,function(line) {
    rec <- jsonlite::fromJSON(line,simplifyVector=FALSE)
    identity <- rec[["identity",exact=TRUE]] %||% list()
    canonical <- rec[["canonical",exact=TRUE]] %||% list()
    id <- scalar(identity[["record_id",exact=TRUE]])
    title <- scalar(canonical[["title",exact=TRUE]])
    abstract <- scalar(canonical[["abstract",exact=TRUE]])
    if(!nzchar(id)||!nzchar(title) ||
       grepl("^pending_workflow[0-9]+$",abstract))
      stop("W05 record missing identity/title or contains status as abstract",call.=FALSE)
    list(record_id=id,title=title,abstract=abstract)
  })
  ids <- vapply(rows,function(x)x$record_id,character(1))
  if(anyDuplicated(ids))stop("Duplicate W05 source identity",call.=FALSE)
  data.frame(record_id=ids,
    title=vapply(rows,function(x)x$title,character(1)),
    abstract=vapply(rows,function(x)x$abstract,character(1)),
    stringsAsFactors=FALSE)
}
w07_bridge_receipt <- function(records,review_id,deposit_id,input_sha) {
  list(schema="lem-w07-shiny-w05-bridge-v1",mode="read_only_handover",
       review_id=review_id,source_stage="W05",source_zenodo_id=deposit_id,
       source_input_sha256=input_sha,record_count=nrow(records),
       record_ids_sha256=w07_bridge_sha(charToRaw(paste(records$record_id,collapse="\n"))),
       target_stage="W07",w06_bypassed=TRUE)
}
`%||%` <- function(x,y) if(is.null(x)||!length(x)) y else x
