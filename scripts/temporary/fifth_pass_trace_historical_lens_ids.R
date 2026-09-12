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

# Trace the exact 262 Lens-ID records retained for review after the user's
# 2026-09-12 adjudication. Do not recompute that adjudication here: a previous
# version did so and drifted from the audited 321/286 split.
review_rows_2026_09_12 <- c(67,82,84,140,149,171,198,274,444,473,620,626,792,793,891,901,905,988,1008,1028,1106,1149,1291,1292,1303,1390,1430,1478,1579,1596,1665,1696,1701,1709,1710,1713,1715,1718,1770,1953,1968,1979,2061,2089,2090,2091,2092,2093,2120,2229,2232,2233,2282,2291,2292,2400,2406,2433,2613,2615,2654,2660,2693,2698,2741,2754,2758,2849,2906,2966,2980,3075,3122,3227,3240,3242,3260,3322,3386,3395,3397,3602,3681,3711,3759,3761,3798,3826,3844,3847,3853,3906,3929,3930,3936,3941,3952,3957,3959,3969,3994,4010,4156,4217,4247,4286,4336,4353,4553,4571,4579,4605,4704,4746,4773,4776,4853,4856,4912,4919,5052,5068,5370,5408,5447,5561,5679,5714,5768,5879,5985,6060,6137,6169,6199,6205,6215,6222,6258,6313,6329,6366,6376,6400,6421,6495,6509,6692,6715,6808,6871,6973,6997,7010,7032,7114,7134,7205,7230,7240,7242,7244,7344,7416,7482,7483,7505,7510,7522,7528,7532,7535,7536,7551,7555,7685,7695,7767,7874,7972,8042,8043,8081,8139,8222,8230,8236,8357,8428,8472,8557,8581,8584,8622,8645,8676,8689,8724,8734,8758,8866,8927,9102,9189,9247,9255,9340,9456,9472,9479,9480,9484,9498,9556,9596,9616,9641,9643,9697,9725,9774,9828,9855,9988,10180,10210,10211,10234,10256,10283,10302,10355,10432,10461,10636,10702,10708,10736,10798,10956,10970,10971,11049,11120,11157,11297,11408,11419,11424,11469,11535,11613,11638,11649,11698,11783,11804,11832,11848,11904,11913,11998)
targets <- Filter(function(x) {
  h <- or_else(x$historical,list())
  identical(as.character(x$historical_source), "production_master") &&
    as.integer(x$historical_row) %in% review_rows_2026_09_12 &&
    nzchar(trimws(as.character(or_else(h$lens_id,""))))
}, res)
if (length(targets) != 262L) stop(sprintf("ERROR: expected 262 adjudicated Lens-ID trace targets, found %d",length(targets)),call.=FALSE)

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
