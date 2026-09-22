#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(jsonlite)
  library(readr)
})

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 5L) {
  stop("Usage: embed_topics.R canonical.jsonl scores.csv input_queue.csv production_manifest.json output.jsonl", call.=FALSE)
}
canonical_path <- args[[1]]
scores_path <- args[[2]]
queue_path <- args[[3]]
manifest_path <- args[[4]]
output_path <- args[[5]]

stopf <- function(...) stop(sprintf(...), call.=FALSE)
trim <- function(x) trimws(as.character(x %||% ""))
`%||%` <- function(x,y) if (is.null(x) || length(x)==0) y else x

scores <- read_csv(scores_path, show_col_types=FALSE, progress=FALSE)
queue <- read_csv(queue_path, show_col_types=FALSE, progress=FALSE)
manifest <- read_json(manifest_path, simplifyVector=FALSE)

required_scores <- c("record_id","path_id","hierarchy_path","confidence_n","confidence_label",
                     "role_a","role_b","role_c","reason_a","reason_b","reason_c")
miss <- setdiff(required_scores, names(scores))
if (length(miss)) stopf("Topic scores missing columns: %s", paste(miss,collapse=", "))
if (!"record_id" %in% names(queue)) stopf("Topic queue has no record_id")
queue_ids <- as.character(queue$record_id)
if (any(!nzchar(queue_ids)) || anyDuplicated(queue_ids)) stopf("Topic queue record_id values are blank or duplicated")
if (any(is.na(scores$confidence_n)) || any(!scores$confidence_n %in% 1:3)) stopf("Invalid confidence_n in topic scores")
if (anyDuplicated(paste(scores$record_id,scores$path_id,sep="::"))) stopf("Duplicate record_id/path_id in topic scores")
if (!all(as.character(scores$record_id) %in% queue_ids)) stopf("Topic scores contain record IDs absent from immutable topic queue")

topic_by_record <- split(scores, as.character(scores$record_id))

vote_obj <- function(row, pass) {
  role <- trim(row[[paste0("role_",pass)]])
  reason <- trim(row[[paste0("reason_",pass)]])
  list(pass=pass, assigned=nzchar(role), role=if(nzchar(role)) role else NULL,
       reason=if(nzchar(reason)) reason else NULL)
}

topic_objects <- function(rid) {
  z <- topic_by_record[[rid]]
  if (is.null(z) || !nrow(z)) return(list())
  lapply(seq_len(nrow(z)), function(i) {
    row <- z[i,]
    list(
      path_id=as.character(row$path_id[[1]]),
      hierarchy_path=as.character(row$hierarchy_path[[1]]),
      stars=as.integer(row$confidence_n[[1]]),
      confidence_label=as.character(row$confidence_label[[1]]),
      votes=list(vote_obj(row,"a"), vote_obj(row,"b"), vote_obj(row,"c"))
    )
  })
}

record_id_of <- function(rec) {
  for (nm in c("record_id","lens_id","id")) {
    x <- rec[[nm]]
    if (!is.null(x) && length(x)) {
      y <- trim(x[[1]])
      if (nzchar(y)) return(y)
    }
  }
  ""
}

dir.create(dirname(output_path), recursive=TRUE, showWarnings=FALSE)
out <- file(output_path, open="wt", encoding="UTF-8")
on.exit(close(out), add=TRUE)

con <- file(canonical_path, open="r", encoding="UTF-8")
on.exit(close(con), add=TRUE)

seen <- character()
n <- 0L
repeat {
  lines <- readLines(con, n=1000L, warn=FALSE)
  if (!length(lines)) break
  lines <- lines[nzchar(trimws(lines))]
  for (line in lines) {
    n <- n + 1L
    rec <- tryCatch(fromJSON(line, simplifyVector=FALSE),
      error=function(e) stopf("Invalid canonical JSONL at record %d: %s", n, conditionMessage(e)))
    rid <- record_id_of(rec)
    if (!nzchar(rid)) stopf("Canonical record %d has no stable record ID", n)
    if (rid %in% seen) stopf("Duplicate canonical record ID: %s", rid)
    seen <- c(seen, rid)

    rec$topics <- topic_objects(rid)
    rec$topic_coding <- list(
      ontology_version="3.6",
      model="gpt-5.6-luna",
      independent_runs=3L,
      aggregation="union of three independent runs; stars equal number of runs assigning pathway",
      source_run_id="35524609662",
      queue_sha256=as.character(manifest$queue_sha256 %||% ""),
      ontology_sha256=as.character(manifest$ontology_sha256 %||% ""),
      system_prompt_sha256=as.character(manifest$system_prompt_sha256 %||% "")
    )
    writeLines(toJSON(rec, auto_unbox=TRUE, null="null", na="null", digits=NA), out)
  }
}

if (length(seen) != length(queue_ids)) {
  missing_from_canonical <- setdiff(queue_ids, seen)
  extra_in_canonical <- setdiff(seen, queue_ids)
  audit <- list(
    canonical_records=length(seen),
    topic_queue_records=length(queue_ids),
    missing_from_canonical=missing_from_canonical,
    extra_in_canonical=extra_in_canonical
  )
  write_json(audit, paste0(output_path,".id_mismatch.json"), pretty=TRUE, auto_unbox=TRUE)
  stopf("Canonical/topic queue ID sets differ: canonical=%d queue=%d missing=%d extra=%d",
        length(seen), length(queue_ids), length(missing_from_canonical), length(extra_in_canonical))
}

cat(sprintf("PASS: embedded topics into %d canonical records; assignments=%d; zero-code=%d\n",
            length(seen), nrow(scores), sum(!queue_ids %in% names(topic_by_record))))
