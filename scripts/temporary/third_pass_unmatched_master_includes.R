#!/usr/bin/env Rscript
suppressPackageStartupMessages({
  library(jsonlite)
  library(stringdist)
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
out_dir <- arg("outdir", "outputs/third_pass_unmatched_includes")
if (is.null(canonical_path) || is.null(still_path)) stop("ERROR: --canonical and --still are required", call.=FALSE)
dir.create(out_dir, recursive=TRUE, showWarnings=FALSE)

norm_text <- function(x) {
  x <- tolower(trimws(as.character(or_else(x, ""))))
  x <- gsub("<[^>]+>", " ", x)
  x <- gsub("[^[:alnum:] ]+", " ", x)
  gsub("[[:space:]]+", " ", trimws(x))
}
tokens <- function(x) {
  z <- unique(strsplit(norm_text(x), " ", fixed=TRUE)[[1]])
  z[nchar(z) >= 3]
}
jaccard_tokens <- function(A, B) {
  if (!length(A) || !length(B)) return(0)
  length(intersect(A,B))/length(union(A,B))
}
seq_sim <- function(a,b) {
  aa <- norm_text(a); bb <- norm_text(b)
  if (!nzchar(aa) || !nzchar(bb)) return(0)
  1 - stringdist(aa, bb, method="lv") / max(nchar(aa), nchar(bb), 1)
}
read_jsonl <- function(path) {
  con <- file(path, "rt", encoding="UTF-8"); on.exit(close(con))
  out <- list(); i <- 0L
  repeat {
    line <- readLines(con, n=1L, warn=FALSE)
    if (!length(line)) break
    if (!nzchar(trimws(line))) next
    i <- i+1L
    out[[i]] <- fromJSON(line, simplifyVector=FALSE)
  }
  out
}
write_jsonl <- function(path, rows) {
  con <- file(path, "wt", encoding="UTF-8"); on.exit(close(con))
  for (x in rows) writeLines(toJSON(x, auto_unbox=TRUE, null="null"), con)
}

targets <- read_jsonl(still_path)
if (length(targets) != 609L) stop(sprintf("ERROR: expected 609 second-pass still-unmatched records; found %d", length(targets)), call.=FALSE)

message("Loading canonical JSONL for third-pass abstract-first linkage")
canon <- list(); by_year <- new.env(hash=TRUE, parent=emptyenv())
add_year <- function(y,i) {
  if (!nzchar(y)) return()
  old <- if (exists(y,by_year,inherits=FALSE)) get(y,by_year) else integer()
  assign(y,c(old,i),by_year)
}
con <- file(canonical_path, "rt", encoding="UTF-8")
i <- 0L
repeat {
  line <- readLines(con,n=1L,warn=FALSE)
  if (!length(line)) break
  if (!nzchar(trimws(line))) next
  i <- i+1L
  rec <- fromJSON(line,simplifyVector=FALSE)
  can <- or_else(rec$canonical,list())
  ident <- or_else(rec$identity,list())
  title <- as.character(or_else(can$title,""))
  abstract <- as.character(or_else(can$abstract,""))
  year <- as.character(or_else(can$year,""))
  journal <- as.character(or_else(can$source,or_else(can$source_title,or_else(can$journal,""))))
  canon[[i]] <- list(
    row=i,
    lens_id=as.character(or_else(ident$lens_id,or_else(rec$record_id,""))),
    title=title,
    title_norm=norm_text(title),
    title_tokens=tokens(title),
    abstract=abstract,
    abstract_norm=norm_text(abstract),
    abstract_tokens=tokens(abstract),
    year=year,
    journal=journal,
    journal_norm=norm_text(journal),
    doi=as.character(or_else(can$doi,""))
  )
  add_year(year,i)
  if (i %% 2000L == 0L) message(sprintf("Canonical index: %d",i))
}
close(con)
message(sprintf("Canonical index complete: %d",length(canon)))

candidate_pool <- function(year) {
  yi <- suppressWarnings(as.integer(year))
  if (is.na(yi)) return(seq_along(canon))
  yrs <- as.character((yi-2L):(yi+2L))
  unique(unlist(lapply(yrs,function(y) if (exists(y,by_year,inherits=FALSE)) get(y,by_year) else integer()), use.names=FALSE))
}

high <- list(); review <- list(); still <- list()
for (k in seq_along(targets)) {
  h <- targets[[k]]
  hh <- or_else(h$historical,list())
  ht <- norm_text(or_else(hh$title,""))
  ha <- norm_text(or_else(hh$abstract,""))
  hj <- norm_text(or_else(hh$journal,or_else(hh$source,"")))
  hy <- as.character(or_else(hh$year,""))
  hty <- tokens(ht); hat <- tokens(ha)
  pool <- candidate_pool(hy)

  scored <- list()
  for (j in pool) {
    cc <- canon[[j]]
    title_j <- jaccard_tokens(hty, cc$title_tokens)
    # Abstract-first: calculate abstract overlap whenever both abstracts are substantive.
    abs_j <- if (nchar(ha) >= 120 && nchar(cc$abstract_norm) >= 120) jaccard_tokens(hat, cc$abstract_tokens) else 0
    if (abs_j < 0.45 && title_j < 0.55) next

    title_s <- if (title_j >= 0.55) seq_sim(ht, cc$title_norm) else 0
    abs_s <- if (abs_j >= 0.55) seq_sim(ha, cc$abstract_norm) else 0
    source_exact <- nzchar(hj) && nzchar(cc$journal_norm) && identical(hj,cc$journal_norm)
    cy <- suppressWarnings(as.integer(cc$year)); hyi <- suppressWarnings(as.integer(hy))
    yd <- if (!is.na(cy) && !is.na(hyi)) abs(cy-hyi) else NA_integer_

    # Composite is for ranking only; acceptance below uses explicit evidence thresholds.
    score <- 0.46*abs_j + 0.22*abs_s + 0.18*title_j + 0.10*title_s + 0.04*as.numeric(source_exact)
    scored[[length(scored)+1L]] <- list(j=j,score=score,abs_j=abs_j,abs_s=abs_s,title_j=title_j,title_s=title_s,source_exact=source_exact,year_diff=yd)
  }

  if (!length(scored)) {
    still[[length(still)+1L]] <- c(h,list(third_pass_reason="no_abstract_or_title_candidate"))
    next
  }
  ord <- order(vapply(scored,function(x)x$score,numeric(1)),decreasing=TRUE)
  scored <- scored[ord]
  b <- scored[[1]]
  second_score <- if (length(scored)>1) scored[[2]]$score else 0
  margin <- b$score-second_score

  # Automatic acceptance requires strong independent evidence and separation from runner-up.
  accept <-
    (b$abs_j >= 0.94 && b$abs_s >= 0.94 && b$title_j >= 0.35 && margin >= 0.025) ||
    (b$abs_j >= 0.88 && b$abs_s >= 0.90 && b$title_j >= 0.65 && b$title_s >= 0.82 && margin >= 0.025) ||
    (b$abs_j >= 0.82 && b$abs_s >= 0.86 && b$title_j >= 0.78 && b$title_s >= 0.88 && !is.na(b$year_diff) && b$year_diff <= 1 && margin >= 0.03) ||
    (b$title_j >= 0.94 && b$title_s >= 0.96 && b$source_exact && !is.na(b$year_diff) && b$year_diff <= 1 && margin >= 0.03)

  needs_review <-
    (b$abs_j >= 0.78 && b$abs_s >= 0.80 && b$title_j >= 0.35) ||
    (b$abs_j >= 0.68 && b$title_j >= 0.65 && b$title_s >= 0.78) ||
    (b$title_j >= 0.85 && b$title_s >= 0.88)

  metrics <- list(
    abstract_token_jaccard=b$abs_j,
    abstract_sequence_similarity=b$abs_s,
    title_token_jaccard=b$title_j,
    title_sequence_similarity=b$title_s,
    source_exact=b$source_exact,
    year_difference=b$year_diff,
    score=b$score,
    margin_to_second=margin
  )
  make_entry <- function(cands, status) {
    list(
      historical_source=h$historical_source,
      historical_row=h$historical_row,
      decision=h$decision,
      historical=h$historical,
      third_pass_status=status,
      candidate_lens_ids=vapply(canon[cands],function(x)x$lens_id,character(1)),
      candidate_rows=vapply(canon[cands],function(x)x$row,integer(1)),
      candidate_titles=vapply(canon[cands],function(x)x$title,character(1)),
      candidate_years=vapply(canon[cands],function(x)x$year,character(1)),
      candidate_dois=vapply(canon[cands],function(x)x$doi,character(1)),
      metrics=metrics
    )
  }

  if (accept) {
    high[[length(high)+1L]] <- make_entry(b$j,"high_confidence")
  } else if (needs_review) {
    top <- vapply(scored[seq_len(min(3,length(scored)))],function(x)x$j,integer(1))
    review[[length(review)+1L]] <- make_entry(top,"review")
  } else {
    still[[length(still)+1L]] <- c(h,list(
      third_pass_reason="below_threshold",
      best_candidate_lens_id=canon[[b$j]]$lens_id,
      best_candidate_title=canon[[b$j]]$title,
      metrics=metrics
    ))
  }
  if (k %% 100L == 0L) message(sprintf("Third pass: %d/609",k))
}

write_jsonl(file.path(out_dir,"high_confidence_matches.jsonl"),high)
write_jsonl(file.path(out_dir,"review_candidates.jsonl"),review)
write_jsonl(file.path(out_dir,"still_unmatched.jsonl"),still)
summary <- list(
  workflow="third_pass_unmatched_master_includes",
  audit_only=TRUE,
  canonical_modified=FALSE,
  targets=length(targets),
  high_confidence_matches=length(high),
  review_candidates=length(review),
  still_unmatched=length(still),
  method="abstract-first linkage within publication year +/-2 years, with title/source corroboration and explicit separation from runner-up"
)
writeLines(toJSON(summary,auto_unbox=TRUE,pretty=TRUE),file.path(out_dir,"summary.json"))
message(toJSON(summary,auto_unbox=TRUE,pretty=TRUE))
message("PASS: third-pass audit complete; canonical JSON was not modified.")
