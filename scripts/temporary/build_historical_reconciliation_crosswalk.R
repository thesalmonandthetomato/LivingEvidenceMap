#!/usr/bin/env Rscript
suppressPackageStartupMessages(library(jsonlite))

args <- commandArgs(trailingOnly=TRUE)
arg <- function(name, default=NULL) {
  hit <- grep(paste0("^--",name,"="), args, value=TRUE)
  if (!length(hit)) return(default)
  sub(paste0("^--",name,"="),"",hit[[1]])
}
or_else <- function(x,y) if (is.null(x) || length(x)==0) y else x

first_matched <- arg("first-matched")
first_ambiguous <- arg("first-ambiguous")
first_conflicts <- arg("first-conflicts")
second_high <- arg("second-high")
second_ambiguous <- arg("second-ambiguous")
third_review <- arg("third-review")
fourth_residual <- arg("fourth-residual")
out <- arg("out","data/adjudication/historical_reconciliation_crosswalk_2026-09-12.csv")
summary_out <- arg("summary","data/adjudication/historical_reconciliation_crosswalk_2026-09-12_summary.json")

req <- c(first_matched,first_ambiguous,first_conflicts,second_high,second_ambiguous,third_review,fourth_residual)
if (any(vapply(req,is.null,logical(1)))) stop("ERROR: all input paths are required",call.=FALSE)

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
scalar <- function(x) {
  if (is.null(x) || !length(x)) return("")
  as.character(x[[1]])
}
specific_species <- function(h) {
  x <- paste(scalar(h$title),scalar(h$abstract),sep="\n")
  grepl("\\bsalmon\\b",x,ignore.case=TRUE,perl=TRUE) ||
    grepl("\\bsalmo\\b",x,ignore.case=TRUE,perl=TRUE) ||
    grepl("\\boncorhynchus\\b",x,ignore.case=TRUE,perl=TRUE) ||
    grepl("\\brainbow[[:space:]-]+trout\\b",x,ignore.case=TRUE,perl=TRUE)
}

rows <- list()
add <- function(hsrc,hrow,hlens="",hdoi="",clens="",relationship,method="",confidence="",decision="",status="resolved",note="") {
  rows[[length(rows)+1L]] <<- data.frame(
    historical_source=as.character(hsrc),
    historical_row=as.integer(hrow),
    historical_lens_id=as.character(hlens),
    historical_doi=as.character(hdoi),
    canonical_lens_id=as.character(clens),
    relationship=as.character(relationship),
    match_method=as.character(method),
    confidence=as.character(confidence),
    historical_screening_decision=as.character(decision),
    adjudication_status=as.character(status),
    note=as.character(note),
    stringsAsFactors=FALSE
  )
}

# 1. First-pass deterministic/high-confidence matches.
for (x in read_jsonl(first_matched)) {
  rb <- or_else(x$ris_bridge,list())
  add(
    x$historical_source,x$historical_row,
    clens=scalar(x$canonical_lens_id),
    relationship="matched",
    method=scalar(x$method),
    confidence=scalar(x$confidence),
    decision=scalar(x$decision),
    note=if (length(rb)) sprintf("RIS bridge: %s row %s via %s",scalar(rb$source),scalar(rb$ris_row),scalar(rb$method)) else ""
  )
}

# 2. Corrected second-pass high-confidence mappings (includes 78 new plus two
# already decisioned first-pass records; duplicate rows will be deduplicated below).
for (x in read_jsonl(second_high)) {
  h <- or_else(x$historical,list())
  cids <- unlist(x$candidate_lens_ids,use.names=FALSE)
  for (cid in cids) add(
    x$historical_source,x$historical_row,
    hlens=scalar(h$lens_id),hdoi=scalar(h$doi),clens=cid,
    relationship="matched",
    method=paste0("second_pass_",scalar(x$match_method)),
    confidence="high",
    decision=scalar(x$decision),
    note="Recovered by corrected second-pass audit."
  )
}

# 3. First-pass ambiguous groups manually adjudicated by user as duplicate
# manifestations / same underlying record. Preserve one row per candidate Lens ID.
manual_ambiguous_keys <- c(
  "production_master:330",
  "excludes_ris:1725",
  "excludes_ris:2760"
)
for (x in read_jsonl(first_ambiguous)) {
  key <- paste0(x$historical_source,":",x$historical_row)
  if (!key %in% manual_ambiguous_keys) next
  h <- or_else(x$historical,list())
  for (cid in unlist(x$candidate_lens_ids,use.names=FALSE)) add(
    x$historical_source,x$historical_row,
    hlens=scalar(h$lens_id),hdoi=scalar(h$doi),clens=cid,
    relationship="duplicate_manifestation",
    method=paste0("manual_",scalar(x$method)),
    confidence="adjudicated",
    decision=scalar(x$decision),
    note="User adjudicated candidate representations as duplicate manifestations / same record."
  )
}

# 4. The 17 first-pass DOI/metadata conflicts were manually adjudicated.
# All were accepted as same-record / duplicate-manifestation links; screening
# retain/exclude is stored independently in the historical decision column.
for (x in read_jsonl(first_conflicts)) {
  h <- or_else(x$historical,list())
  for (cid in unlist(x$candidate_lens_ids,use.names=FALSE)) add(
    x$historical_source,x$historical_row,
    hlens=scalar(h$lens_id),hdoi=scalar(h$doi),clens=cid,
    relationship="duplicate_manifestation",
    method=paste0("manual_",scalar(x$method)),
    confidence="adjudicated",
    decision=scalar(x$decision),
    note="Manually resolved DOI/metadata conflict; canonical candidate accepted as same-record/duplicate manifestation."
  )
}

# 5. Corrected second-pass unresolved Erratum ambiguity. Keep it as unresolved,
# not as a positive mapping.
for (x in read_jsonl(second_ambiguous)) {
  h <- or_else(x$historical,list())
  for (cid in unlist(x$candidate_lens_ids,use.names=FALSE)) add(
    x$historical_source,x$historical_row,
    hlens=scalar(h$lens_id),hdoi=scalar(h$doi),clens=cid,
    relationship="possible_match",
    method=scalar(x$match_method),
    confidence="ambiguous",
    decision=scalar(x$decision),
    status="unresolved",
    note="Do not auto-link: unresolved ambiguity."
  )
}

# 6. Third-pass manual adjudications.
for (x in read_jsonl(third_review)) {
  h <- or_else(x$historical,list())
  cid <- scalar(x$candidate_lens_ids)
  if (identical(as.integer(x$historical_row),2172L)) {
    add(x$historical_source,x$historical_row,scalar(h$lens_id),scalar(h$doi),cid,
        "duplicate_manifestation","manual_third_pass","adjudicated",scalar(x$decision),"resolved",
        "User adjudicated the reprint as a duplicate manifestation of the same article.")
  } else if (identical(as.integer(x$historical_row),9777L)) {
    add(x$historical_source,x$historical_row,scalar(h$lens_id),scalar(h$doi),cid,
        "non_match","manual_third_pass","adjudicated",scalar(x$decision),"resolved",
        "User adjudicated formal comment as a different record; preserve as a negative pair.")
  }
}

# 7. Preserve the known false DOI-prefix collision as a negative pair.
add("production_master",9719,"","","098-323-147-549-973",
    "non_match","manual_doi_normalisation_correction","adjudicated","include","resolved",
    "False SICI DOI-prefix collision from obsolete DOI normaliser; do not match.")

# 8. User decision: 321 fourth-pass residuals with no standalone salmon, Salmo,
# Oncorhynchus or rainbow trout in title/abstract are manual excludes / ignored.
manual_excl <- 0L
for (x in read_jsonl(fourth_residual)) {
  h <- or_else(x$historical,list())
  if (specific_species(h)) next
  manual_excl <- manual_excl+1L
  add(x$historical_source,x$historical_row,scalar(h$lens_id),scalar(h$doi),"",
      "manual_exclude_no_canonical_match","manual_species_term_review","adjudicated","exclude","resolved",
      "User instructed: exclude and ignore for now; no specific salmon/Salmo/Oncorhynchus/rainbow trout term in historical title or abstract.")
}
if (manual_excl != 321L) stop(sprintf("ERROR: expected 321 manual exclude rows, got %d",manual_excl),call.=FALSE)

df <- do.call(rbind,rows)

# Deduplicate exact rows only; retain one-to-many duplicate manifestations and negative pairs.
dedup_key <- do.call(paste,c(df,sep="\x1f"))
df <- df[!duplicated(dedup_key),,drop=FALSE]

# Deterministic ordering.
ord <- order(df$historical_source,df$historical_row,df$relationship,df$canonical_lens_id)
df <- df[ord,,drop=FALSE]

dir.create(dirname(out),recursive=TRUE,showWarnings=FALSE)
write.csv(df,out,row.names=FALSE,na="")

summary <- list(
  created_on="2026-09-12",
  purpose="Persistent crosswalk of historical screening records to canonical Lens IDs and previously adjudicated negative/unresolved relationships.",
  rows=nrow(df),
  unique_historical_records=nrow(unique(df[c("historical_source","historical_row")])),
  positive_link_rows=sum(df$relationship %in% c("matched","duplicate_manifestation")),
  negative_pair_rows=sum(df$relationship=="non_match"),
  unresolved_rows=sum(df$adjudication_status=="unresolved"),
  manual_exclude_rows=sum(df$relationship=="manual_exclude_no_canonical_match"),
  relationship_counts=as.list(table(df$relationship)),
  rules=list(
    use_positive_links="Reuse matched/duplicate_manifestation rows before running any new matcher.",
    respect_negative_pairs="Never propose canonical_lens_id pairs recorded as non_match unless explicitly re-adjudicated.",
    respect_manual_excludes="Do not rematch manual_exclude_no_canonical_match rows unless explicitly revisited.",
    unresolved="possible_match + unresolved must remain manual review items."
  )
)
writeLines(toJSON(summary,auto_unbox=TRUE,pretty=TRUE,null="null"),summary_out)

cat(toJSON(summary,auto_unbox=TRUE,pretty=TRUE,null="null"),"\n")
cat("PASS: persistent historical reconciliation crosswalk built.\n")
