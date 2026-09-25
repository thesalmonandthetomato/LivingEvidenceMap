#!/usr/bin/env Rscript
suppressPackageStartupMessages({
  library(jsonlite)
  library(dplyr)
  library(stringr)
  library(readr)
})

args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag, default=NULL){
  i <- match(flag,args)
  if(is.na(i)) return(default)
  if(i==length(args)) stop(sprintf("Missing value after %s",flag),call.=FALSE)
  args[[i+1L]]
}
input_path <- arg("--input")
output_dir <- arg("--output-dir","outputs/workflow03_title_notice_scan")
if(is.null(input_path) || !file.exists(input_path)) stop("Required canonical --input",call.=FALSE)
dir.create(output_dir,recursive=TRUE,showWarnings=FALSE)

`%||%` <- function(x,y) if(is.null(x)) y else x
clean <- function(x){
  if(is.null(x)||!length(x)) return("")
  s <- trimws(gsub("[[:space:]]+"," ",as.character(x[[1L]])))
  if(is.na(s)) "" else s
}

# Diagnostic vocabulary only. No term here is yet an inclusion/exclusion rule.
patterns <- tibble::tribble(
  ~candidate_group, ~pattern,
  "retraction", "retraction",
  "retraction", "retracted",
  "retraction", "retraction notice",
  "retraction", "notice of retraction",
  "withdrawal", "withdrawal",
  "withdrawal", "withdrawn",
  "withdrawal", "withdrawal notice",
  "withdrawal", "notice of withdrawal",
  "correction", "correction",
  "correction", "correction notice",
  "correction", "notice of correction",
  "correction", "publisher correction",
  "correction", "author correction",
  "correction", "corrections",
  "corrigendum", "corrigendum",
  "erratum", "erratum",
  "erratum", "errata",
  "concern", "expression of concern",
  "concern", "editorial expression of concern",
  "concern", "notice of concern",
  "warning", "warning",
  "warning", "warning notice",
  "warning", "editorial warning",
  "notice", "editorial notice",
  "notice", "publisher notice",
  "notice", "notice",
  "addendum", "addendum",
  "update", "update",
  "update", "updated",
  "amendment", "amendment",
  "amendment", "amended",
  "comment", "comment on",
  "response", "response to",
  "reply", "reply to"
)

# Allow leading punctuation/brackets/HTML-like wrappers before the first lexical token,
# but require a word boundary after the candidate phrase.
prefix_regex <- function(p){
  escaped <- stringr::str_replace_all(p, "([\\.\\^\\$\\|\\(\\)\\[\\]\\{\\}\\*\\+\\?\\\\])", "\\\\\1")
  paste0("(?i)^[[:space:][:punct:]]*", escaped, "\\b")
}

con <- file(input_path,"rt",encoding="UTF-8")
on.exit(close(con),add=TRUE)
out <- list(); n <- 0L; total <- 0L
repeat{
  line <- readLines(con,n=1L,warn=FALSE)
  if(!length(line)) break
  if(!nzchar(trimws(line))) next
  total <- total+1L
  r <- fromJSON(line,simplifyVector=FALSE)
  rid <- clean((r$identity %||% list())$record_id)
  can <- r$canonical %||% list()
  title <- clean(can$title)
  if(!nzchar(title)) next

  hits <- patterns |>
    mutate(hit = vapply(pattern, function(p) str_detect(title, regex(prefix_regex(p))), logical(1))) |>
    filter(hit)
  if(!nrow(hits)) next

  mans <- r$manifestations %||% list()
  sources <- sort(unique(vapply(mans,function(m)clean(m$source),character(1))))
  openalex_ids <- unique(vapply(Filter(function(m) identical(clean(m$source),"openalex"), mans),
                                function(m) clean(m$source_record_id), character(1)))
  openalex_ids <- openalex_ids[nzchar(openalex_ids)]

  for(i in seq_len(nrow(hits))){
    n <- n+1L
    out[[n]] <- tibble(
      record_id = rid,
      doi = clean(can$doi),
      openalex_id = paste(openalex_ids,collapse="; "),
      matched_group = hits$candidate_group[[i]],
      matched_prefix = hits$pattern[[i]],
      title = title,
      year = clean(can$year),
      journal = clean(can$journal),
      sources = paste(sources,collapse="; ")
    )
  }
}
close(con);on.exit(NULL,add=FALSE)

matches <- if(length(out)) bind_rows(out) else tibble(
  record_id=character(),doi=character(),openalex_id=character(),
  matched_group=character(),matched_prefix=character(),title=character(),
  year=character(),journal=character(),sources=character()
)

# Keep the most specific/longest prefix per record to avoid duplicate rows where
# e.g. "retraction notice" also matches "retraction".
matches <- matches |>
  mutate(prefix_length=nchar(matched_prefix)) |>
  arrange(record_id,desc(prefix_length),matched_prefix) |>
  group_by(record_id) |>
  slice(1) |>
  ungroup() |>
  select(-prefix_length) |>
  arrange(matched_group,matched_prefix,title)

summary <- matches |>
  count(matched_group,matched_prefix,name="records") |>
  arrange(matched_group,desc(records),matched_prefix)

write_csv(matches,file.path(output_dir,"candidate_publication_notice_titles.csv"))
write_csv(summary,file.path(output_dir,"candidate_publication_notice_prefix_summary.csv"))

report <- list(
  schema="living-evidence-map-workflow03-title-notice-diagnostic-v1",
  status="PASS",
  canonical_records_scanned=total,
  matched_records=nrow(matches),
  candidate_groups=sort(unique(matches$matched_group)),
  note="Diagnostic only: no title prefix is yet an exclusion or publication-status rule."
)
writeLines(toJSON(report,auto_unbox=TRUE,pretty=TRUE,null="null"),
           file.path(output_dir,"report.json"),useBytes=TRUE)

cat(sprintf("PASS: scanned %d canonical records; %d records matched candidate publication-notice prefixes\n",
            total,nrow(matches)))
if(nrow(summary)) print(summary,n=Inf)
