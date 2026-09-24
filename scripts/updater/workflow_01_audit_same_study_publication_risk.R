#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(jsonlite)
  library(digest)
})

args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag,default=NULL) {
  i <- match(flag,args)
  if (is.na(i)) return(default)
  if (i==length(args)) stop(sprintf("Missing value after %s",flag),call.=FALSE)
  args[[i+1L]]
}

input_path <- arg("--input")
output_path <- arg("--output")
flagged_path <- arg("--flagged-output")
if (any(vapply(list(input_path,output_path,flagged_path),is.null,logical(1)))) {
  stop("Required: --input --output --flagged-output",call.=FALSE)
}

lines <- readLines(input_path,warn=FALSE,encoding="UTF-8")
lines <- lines[nzchar(trimws(lines))]
rows <- lapply(lines,fromJSON,simplifyVector=FALSE)

scalar <- function(x) {
  if (is.null(x)||!length(x)||is.na(x)) return("")
  trimws(tolower(as.character(x)))
}
same_nonempty <- function(a,b) nzchar(scalar(a)) && identical(scalar(a),scalar(b))
different_nonempty <- function(a,b) nzchar(scalar(a)) && nzchar(scalar(b)) && !identical(scalar(a),scalar(b))

flag_reason <- function(z) {
  if (!identical(z$promotion,"duplicate")) return(character())

  a <- z$record_i
  b <- z$record_j
  e <- z$deterministic_evidence
  reasons <- character()

  # Different conventional publication coordinates are a warning that the records
  # may be distinct outputs from one study rather than versions of one publication.
  if (different_nonempty(a$journal,b$journal)) reasons <- c(reasons,"different_journal")
  if (different_nonempty(a$year,b$year)) reasons <- c(reasons,"different_year")
  if (different_nonempty(a$volume,b$volume)) reasons <- c(reasons,"different_volume")
  if (different_nonempty(a$issue,b$issue)) reasons <- c(reasons,"different_issue")
  if (different_nonempty(a$pages,b$pages)) reasons <- c(reasons,"different_pages")

  # Distinct non-empty DOIs are not decisive, but paired with publication-coordinate
  # differences they increase the risk of companion/follow-up papers.
  if (different_nonempty(a$doi,b$doi)) reasons <- c(reasons,"different_doi")

  # Titles that are not exact deserve human inspection when other coordinates differ,
  # because related papers from the same study can have highly similar abstracts.
  exact_title <- isTRUE(e$exact_title)
  if (!exact_title && any(grepl("^different_",reasons))) reasons <- c(reasons,"non_exact_title")

  # Identifier conflict was already a deterministic warning.
  if (isTRUE(e$identifier_conflict)) reasons <- c(reasons,"identifier_conflict")

  # Explicit preprint pairs are generally legitimate manifestations, so do not flag
  # merely for expected journal/year/page changes unless there is identifier conflict.
  if (isTRUE(e$preprint_pair) && !"identifier_conflict" %in% reasons) return(character())

  unique(reasons)
}

flagged <- list()
out_rows <- vector("list",length(rows))
for (i in seq_along(rows)) {
  z <- rows[[i]]
  reasons <- flag_reason(z)
  z$same_study_distinct_publication_audit <- list(
    flagged=length(reasons)>0L,
    reasons=reasons
  )
  if (length(reasons)>0L) {
    # Do not overturn the model. Escalate its automatic duplicate decision to human review.
    z$promotion_before_same_study_audit <- z$promotion
    z$promotion <- "human_review"
    z$promotion_reason <- "same_study_distinct_publication_risk"
    flagged[[length(flagged)+1L]] <- z
  }
  out_rows[[i]] <- z
}

write_jsonl <- function(x,path) {
  dir.create(dirname(path),recursive=TRUE,showWarnings=FALSE)
  con <- file(path,"wt",encoding="UTF-8")
  on.exit(close(con),add=TRUE)
  for (z in x) writeLines(toJSON(z,auto_unbox=TRUE,null="null",na="null"),con,useBytes=TRUE)
}
write_jsonl(out_rows,output_path)
write_jsonl(flagged,flagged_path)

summary <- list(
  schema="living-evidence-map-workflow01-same-study-publication-audit-v1",
  total_cases=length(rows),
  original_automatic_duplicates=sum(vapply(rows,function(z)identical(z$promotion,"duplicate"),logical(1))),
  flagged_automatic_duplicates=length(flagged),
  rule="Escalate automatic duplicate decisions with bibliographic signals compatible with distinct publications from the same underlying study; preprint pairs are exempt unless identifier conflict is present.",
  input_sha256=digest(file=input_path,algo="sha256",serialize=FALSE),
  output_sha256=digest(file=output_path,algo="sha256",serialize=FALSE),
  flagged_sha256=digest(file=flagged_path,algo="sha256",serialize=FALSE)
)
writeLines(toJSON(summary,auto_unbox=TRUE,pretty=TRUE,null="null"),
           paste0(output_path,".audit.json"))
cat(sprintf("PASS: same-study/distinct-publication audit flagged %d automatic duplicate decisions for human review\n",
            length(flagged)))
