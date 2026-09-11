#!/usr/bin/env Rscript
suppressPackageStartupMessages({
  library(jsonlite)
  library(digest)
})

args <- commandArgs(trailingOnly = TRUE)
arg <- function(name, default = NULL) {
  hit <- grep(paste0("^--", name, "="), args, value = TRUE)
  if (!length(hit)) return(default)
  sub(paste0("^--", name, "="), "", hit[[1]])
}
or_else <- function(x, y) if (is.null(x) || length(x) == 0) y else x
canonical_path <- arg("canonical")
still_path <- arg("still")
out_dir <- arg("outdir", "outputs/fourth_pass_identity_recovery")
if (is.null(canonical_path) || is.null(still_path)) stop("ERROR: --canonical and --still are required", call.=FALSE)
dir.create(out_dir, recursive=TRUE, showWarnings=FALSE)

norm_doi <- function(x) {
  s <- tolower(trimws(as.character(or_else(x, ""))))
  s <- sub("^https?://(dx\\.)?doi\\.org/", "", s)
  s <- sub("^doi:[[:space:]]*", "", s)
  # Preserve SICI-style DOI punctuation, including angle brackets and semicolons.
  m <- regexpr("10\\.[0-9]{4,9}/[^[:space:]\"]+", s, perl=TRUE)
  if (m[1] > 0) s <- regmatches(s, m)
  sub("[\\.,;:\\)\\]\\}]+$", "", s)
}
lens_re <- "^[0-9]{3}-[0-9]{3}-[0-9]{3}-[0-9]{3}-[0-9Xx]{3}$"

read_jsonl <- function(path) {
  con <- file(path,"rt",encoding="UTF-8"); on.exit(close(con))
  out <- list(); i <- 0L
  repeat {
    line <- readLines(con,n=1L,warn=FALSE)
    if (!length(line)) break
    if (!nzchar(trimws(line))) next
    i <- i+1L
    out[[i]] <- fromJSON(line,simplifyVector=FALSE)
  }
  out
}
write_jsonl <- function(path, rows) {
  con <- file(path,"wt",encoding="UTF-8"); on.exit(close(con))
  for (x in rows) writeLines(toJSON(x,auto_unbox=TRUE,null="null"),con)
}

collect_scalars <- function(x, path="") {
  out <- list()
  rec <- function(obj, p) {
    if (is.null(obj)) return()
    if (is.atomic(obj) && length(obj) == 1L) {
      out[[length(out)+1L]] <<- list(path=p, value=as.character(obj))
    } else if (is.atomic(obj)) {
      for (ii in seq_along(obj)) rec(obj[[ii]], paste0(p,"[",ii,"]"))
    } else if (is.list(obj)) {
      nms <- names(obj)
      if (is.null(nms)) {
        for (ii in seq_along(obj)) rec(obj[[ii]], paste0(p,"[",ii,"]"))
      } else {
        for (nm in nms) rec(obj[[nm]], if (nzchar(p)) paste0(p,".",nm) else nm)
      }
    }
  }
  rec(x,path)
  out
}

targets <- read_jsonl(still_path)
if (length(targets) != 607L) stop(sprintf("ERROR: expected 607 residuals after third pass; found %d", length(targets)), call.=FALSE)

message("Indexing all Lens IDs and DOI-like values anywhere in canonical records")
lens_index <- new.env(hash=TRUE,parent=emptyenv())
doi_index <- new.env(hash=TRUE,parent=emptyenv())
canon_meta <- list()

add_idx <- function(env,key,row,path) {
  if (!nzchar(key)) return()
  old <- if (exists(key,env,inherits=FALSE)) get(key,env) else list()
  assign(key,c(old,list(list(row=row,path=path))),env)
}

con <- file(canonical_path,"rt",encoding="UTF-8")
i <- 0L
repeat {
  line <- readLines(con,n=1L,warn=FALSE)
  if (!length(line)) break
  if (!nzchar(trimws(line))) next
  i <- i+1L
  rec <- fromJSON(line,simplifyVector=FALSE)
  can <- or_else(rec$canonical,list())
  ident <- or_else(rec$identity,list())
  canon_meta[[i]] <- list(
    lens_id=as.character(or_else(ident$lens_id,or_else(rec$record_id,""))),
    title=as.character(or_else(can$title,"")),
    year=as.character(or_else(can$year,"")),
    doi=as.character(or_else(can$doi,""))
  )
  vals <- collect_scalars(rec)
  for (v in vals) {
    vv <- trimws(v$value)
    if (grepl(lens_re,vv,perl=TRUE)) add_idx(lens_index,toupper(vv),i,v$path)
    d <- norm_doi(vv)
    if (nzchar(d) && grepl("^10\\.[0-9]{4,9}/",d,perl=TRUE)) add_idx(doi_index,d,i,v$path)
  }
  if (i %% 2000L == 0L) message(sprintf("Indexed canonical records: %d",i))
}
close(con)

resolved <- list(); ambiguous <- list(); unmatched <- list()
for (k in seq_along(targets)) {
  h <- targets[[k]]
  hh <- or_else(h$historical,list())
  lens <- toupper(as.character(or_else(hh$lens_id,"")))
  doi <- norm_doi(or_else(hh$doi,""))
  lens_hits <- if (nzchar(lens) && exists(lens,lens_index,inherits=FALSE)) get(lens,lens_index) else list()
  doi_hits <- if (nzchar(doi) && exists(doi,doi_index,inherits=FALSE)) get(doi,doi_index) else list()
  rows_l <- unique(vapply(lens_hits,function(x)x$row,integer(1)))
  rows_d <- unique(vapply(doi_hits,function(x)x$row,integer(1)))
  candidate_rows <- unique(c(rows_l,rows_d))

  evidence <- list(
    historical_lens_id=if(nzchar(lens)) lens else NULL,
    historical_doi=if(nzchar(doi)) doi else NULL,
    lens_candidate_rows=rows_l,
    doi_candidate_rows=rows_d,
    lens_paths=lapply(lens_hits,function(x)x$path),
    doi_paths=lapply(doi_hits,function(x)x$path)
  )

  entry <- function(status) list(
    historical_source=h$historical_source,
    historical_row=h$historical_row,
    decision=h$decision,
    historical=h$historical,
    identity_status=status,
    candidate_rows=candidate_rows,
    candidate_lens_ids=vapply(canon_meta[candidate_rows],function(x)x$lens_id,character(1)),
    candidate_titles=vapply(canon_meta[candidate_rows],function(x)x$title,character(1)),
    candidate_years=vapply(canon_meta[candidate_rows],function(x)x$year,character(1)),
    candidate_dois=vapply(canon_meta[candidate_rows],function(x)x$doi,character(1)),
    evidence=evidence
  )

  if (length(candidate_rows)==1L) {
    # Require Lens and DOI to agree if both independently hit.
    consistent <- (!length(rows_l) || !length(rows_d) || identical(rows_l,rows_d))
    if (consistent) resolved[[length(resolved)+1L]] <- entry("unique_identity_match")
    else ambiguous[[length(ambiguous)+1L]] <- entry("conflicting_identity_evidence")
  } else if (length(candidate_rows)>1L) {
    ambiguous[[length(ambiguous)+1L]] <- entry("multiple_identity_candidates")
  } else {
    unmatched[[length(unmatched)+1L]] <- c(h,list(fourth_pass_reason="lens_id_and_doi_absent_from_all_canonical_fields"))
  }
  if (k %% 100L == 0L) message(sprintf("Fourth pass: %d/607",k))
}

write_jsonl(file.path(out_dir,"unique_identity_matches.jsonl"),resolved)
write_jsonl(file.path(out_dir,"ambiguous_identity_matches.jsonl"),ambiguous)
write_jsonl(file.path(out_dir,"still_unmatched.jsonl"),unmatched)
summary <- list(
  workflow="fourth_pass_identity_recovery",
  audit_only=TRUE,
  canonical_modified=FALSE,
  targets=length(targets),
  unique_identity_matches=length(resolved),
  ambiguous_identity_matches=length(ambiguous),
  still_unmatched=length(unmatched),
  method="Search historical Lens ID and DOI across every scalar field in each full canonical JSON record, including provenance, alternate identifiers, deduplication and publication-version metadata."
)
writeLines(toJSON(summary,auto_unbox=TRUE,pretty=TRUE),file.path(out_dir,"summary.json"))
message(toJSON(summary,auto_unbox=TRUE,pretty=TRUE))
message("PASS: fourth-pass identity recovery audit complete; canonical JSON not modified.")
