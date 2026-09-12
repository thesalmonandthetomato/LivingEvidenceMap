#!/usr/bin/env Rscript
suppressPackageStartupMessages(library(jsonlite))

args <- commandArgs(trailingOnly = TRUE)
arg <- function(name, default=NULL) {
  hit <- grep(paste0("^--", name, "="), args, value=TRUE)
  if (!length(hit)) return(default)
  sub(paste0("^--", name, "="), "", hit[[1]])
}
or_else <- function(x,y) if (is.null(x) || length(x)==0) y else x

residual_path <- arg("residual")
historical_root <- arg("historical-root")
stage00 <- arg("stage00")
enriched <- arg("enriched")
dedup <- arg("dedup")
publication <- arg("publication")
out_dir <- arg("outdir","outputs/fifth_pass_trace")
if (any(vapply(list(residual_path,historical_root,stage00,enriched,dedup,publication), is.null, logical(1)))) {
  stop("ERROR: missing required arguments", call.=FALSE)
}
dir.create(out_dir, recursive=TRUE, showWarnings=FALSE)

read_jsonl <- function(path) {
  con <- file(path,"rt",encoding="UTF-8"); on.exit(close(con))
  out <- list(); i <- 0L
  repeat {
    z <- readLines(con,n=1L,warn=FALSE)
    if (!length(z)) break
    if (!nzchar(trimws(z))) next
    i <- i+1L
    out[[i]] <- fromJSON(z,simplifyVector=FALSE)
  }
  out
}
read_ids <- function(path) {
  con <- file(path,"rt",encoding="UTF-8"); on.exit(close(con))
  e <- new.env(hash=TRUE,parent=emptyenv())
  n <- 0L
  repeat {
    z <- readLines(con,n=1L,warn=FALSE)
    if (!length(z)) break
    if (!nzchar(trimws(z))) next
    n <- n+1L
    r <- fromJSON(z,simplifyVector=FALSE)
    lid <- as.character(or_else((or_else(r$identity,list()))$lens_id,""))
    if (nzchar(lid)) assign(lid,TRUE,e)
  }
  list(env=e,n=n)
}
contains_specific <- function(title,abstract) {
  x <- paste(or_else(title,""), or_else(abstract,""), sep="\n")
  grepl("\\bsalmon\\b", x, ignore.case=TRUE, perl=TRUE) ||
    grepl("\\bsalmo\\b", x, ignore.case=TRUE, perl=TRUE) ||
    grepl("\\boncorhynchus\\b", x, ignore.case=TRUE, perl=TRUE) ||
    grepl("\\brainbow[[:space:]-]+trout\\b", x, ignore.case=TRUE, perl=TRUE)
}
count_fixed <- function(path, needle) {
  if (!file.exists(path)) return(NA_integer_)
  con <- file(path,"rt",encoding="UTF-8"); on.exit(close(con))
  n <- 0L
  repeat {
    z <- readLines(con,n=5000L,warn=FALSE)
    if (!length(z)) break
    n <- n + sum(grepl(needle,z,fixed=TRUE))
  }
  n
}

res <- read_jsonl(residual_path)
if (length(res) != 607L) stop(sprintf("ERROR: expected 607 residual records, found %d",length(res)),call.=FALSE)

targets <- list()
manual_excluded <- list()
for (x in res) {
  h <- or_else(x$historical,list())
  lid <- trimws(as.character(or_else(h$lens_id,"")))
  spec <- contains_specific(h$title,h$abstract)
  if (!spec) {
    manual_excluded[[length(manual_excluded)+1L]] <- x
  } else if (nzchar(lid)) {
    targets[[length(targets)+1L]] <- x
  }
}
if (length(manual_excluded) != 321L) stop(sprintf("ERROR: expected 321 manual excludes, found %d",length(manual_excluded)),call.=FALSE)
if (length(targets) != 262L) stop(sprintf("ERROR: expected 262 Lens-ID trace targets, found %d",length(targets)),call.=FALSE)

stages <- list(
  workflow00=read_ids(stage00),
  abstract_enriched=read_ids(enriched),
  deduplicated=read_ids(dedup),
  publication_status=read_ids(publication)
)

hist_files <- c(
  search_results_corrected=file.path(historical_root,"searching/search_results_lens_corrected.txt"),
  search_results_deduplicated=file.path(historical_root,"searching/search_results_lens_deduplicated.txt"),
  deduplicated_incl_cchasing=file.path(historical_root,"searching/deduplicated_results_incl_cchasing.txt"),
  includes_ris=file.path(historical_root,"screening/INCLUDES.ris")
)
for (p in hist_files) if (!file.exists(p)) stop(sprintf("ERROR: missing historical source file %s",p),call.=FALSE)

rows <- vector("list",length(targets))
for (i in seq_along(targets)) {
  x <- targets[[i]]
  h <- or_else(x$historical,list())
  lid <- trimws(as.character(h$lens_id))
  hist_counts <- vapply(hist_files,count_fixed,integer(1),needle=lid)
  present <- vapply(stages,function(s) exists(lid,s$env,inherits=FALSE),logical(1))
  earliest_loss <- if (!present[["workflow00"]]) {
    "before_or_at_workflow00_fresh_Lens_query"
  } else if (!present[["abstract_enriched"]]) {
    "abstract_enrichment"
  } else if (!present[["deduplicated"]]) {
    "deduplication"
  } else if (!present[["publication_status"]]) {
    "publication_status"
  } else {
    "present_through_publication_status"
  }
  rows[[i]] <- data.frame(
    historical_row=as.integer(or_else(x$historical_row,NA_integer_)),
    lens_id=lid,
    doi=as.character(or_else(h$doi,"")),
    year=as.character(or_else(h$year,"")),
    title=as.character(or_else(h$title,"")),
    historical_search_corrected_hits=hist_counts[["search_results_corrected"]],
    historical_search_deduplicated_hits=hist_counts[["search_results_deduplicated"]],
    historical_dedup_incl_cchasing_hits=hist_counts[["deduplicated_incl_cchasing"]],
    historical_includes_ris_hits=hist_counts[["includes_ris"]],
    present_workflow00=present[["workflow00"]],
    present_abstract_enriched=present[["abstract_enriched"]],
    present_deduplicated=present[["deduplicated"]],
    present_publication_status=present[["publication_status"]],
    earliest_loss=earliest_loss,
    stringsAsFactors=FALSE
  )
  if (i %% 50L == 0L) message(sprintf("Traced %d/262",i))
}
df <- do.call(rbind,rows)

write.csv(df,file.path(out_dir,"trace_262_lens_ids.csv"),row.names=FALSE,na="")
writeLines(toJSON(list(
  decision="manual_exclude_ignore_for_now",
  record_count=321,
  basis="No standalone salmon, Salmo, Oncorhynchus, or rainbow trout in historical title or abstract.",
  canonical_action="none",
  note="User instructed these 321 unmatched historical records to be treated as excludes and ignored for now."
),auto_unbox=TRUE,pretty=TRUE),file.path(out_dir,"manual_excluded_321_note.json"))

loss_counts <- as.list(table(df$earliest_loss))
hist_presence <- list(
  in_search_results_corrected=sum(df$historical_search_corrected_hits>0,na.rm=TRUE),
  in_search_results_deduplicated=sum(df$historical_search_deduplicated_hits>0,na.rm=TRUE),
  in_deduplicated_results_incl_cchasing=sum(df$historical_dedup_incl_cchasing_hits>0,na.rm=TRUE),
  in_includes_ris_by_lens_id=sum(df$historical_includes_ris_hits>0,na.rm=TRUE)
)
summary <- list(
  workflow="fifth_pass_trace_historical_lens_ids",
  audit_only=TRUE,
  canonical_modified=FALSE,
  residual_input=607,
  manual_excluded_ignored=321,
  relevance_review_set=286,
  lens_id_trace_targets=262,
  no_lens_id_in_review_set=24,
  stage_cardinality=list(
    workflow00=stages$workflow00$n,
    abstract_enriched=stages$abstract_enriched$n,
    deduplicated=stages$deduplicated$n,
    publication_status=stages$publication_status$n
  ),
  historical_presence=hist_presence,
  earliest_loss_counts=loss_counts
)
writeLines(toJSON(summary,auto_unbox=TRUE,pretty=TRUE,null="null"),file.path(out_dir,"summary.json"))

exid <- "075-265-152-590-041"
ex <- df[df$lens_id==exid,,drop=FALSE]
if (nrow(ex)!=1L) stop(sprintf("ERROR: expected exact example %s once, found %d",exid,nrow(ex)),call.=FALSE)
writeLines(toJSON(as.list(ex[1,]),auto_unbox=TRUE,pretty=TRUE,null="null"),file.path(out_dir,"example_075-265-152-590-041.json"))

message(toJSON(summary,auto_unbox=TRUE,pretty=TRUE,null="null"))
message("PASS: fifth-pass Lens-ID stage trace complete; no source/canonical files modified.")
