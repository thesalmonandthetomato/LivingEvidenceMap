#!/usr/bin/env Rscript
suppressPackageStartupMessages(library(jsonlite))

args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag, default=NULL) {
  i <- match(flag,args)
  if (is.na(i)) return(default)
  if (i==length(args)) stop(sprintf("Missing value after %s",flag),call.=FALSE)
  args[[i+1L]]
}
old_dir <- arg("--old-dir")
current_lens <- arg("--current-lens")
current_scopus <- arg("--current-scopus")
current_openalex <- arg("--current-openalex")
current_agricola <- arg("--current-agricola")
current_wos <- arg("--current-wos")
expected_prior <- suppressWarnings(as.integer(arg("--expected-prior-manifestations",NA_character_)))
output_dir <- arg("--output-dir")
if (any(vapply(list(old_dir,current_lens,current_scopus,current_openalex,current_agricola,current_wos,output_dir),is.null,logical(1)))) {
  stop("Required: --old-dir --current-lens --current-scopus --current-openalex --current-agricola --current-wos --output-dir",call.=FALSE)
}
dir.create(output_dir,recursive=TRUE,showWarnings=FALSE)

`%||%` <- function(x,y) if (is.null(x)) y else x
scalar <- function(x) {
  if (is.null(x)||!length(x)) return(NULL)
  y <- trimws(as.character(x[[1L]]))
  if (!nzchar(y)) NULL else y
}
source_kind <- function(r) {
  if (is.list(r$lens)) return("lens")
  p <- scalar((r$source %||% list())$provider)
  if (identical(p,"scopus")) return("scopus")
  if (identical(p,"openalex")) return("openalex")
  if (identical(p,"agricola_via_europe_pmc")) return("agricola")
  if (identical(p,"wos_starter")) return("wos")
  stop(sprintf("Unknown source provider: %s",p %||% "<missing>"),call.=FALSE)
}
source_record_id <- function(r) {
  src <- source_kind(r)
  if (src=="lens") {
    return(as.character((r$identity %||% list())$lens_id %||% (r$identity %||% list())$record_id %||% ""))
  }
  as.character((r$sidecar_identity %||% list())$sidecar_record_id %||% "")
}
read_lines_nonempty <- function(path) {
  x <- readLines(path,warn=FALSE,encoding="UTF-8")
  x[nzchar(trimws(x))]
}
ids_for_lines <- function(lines, expected_source) {
  ids <- character(length(lines))
  for (i in seq_along(lines)) {
    r <- fromJSON(lines[[i]],simplifyVector=FALSE)
    src <- source_kind(r)
    if (!identical(src,expected_source)) stop(sprintf("Expected %s but found %s at line %d",expected_source,src,i),call.=FALSE)
    rid <- source_record_id(r)
    if (!nzchar(rid)) stop(sprintf("%s line %d lacks source ID",expected_source,i),call.=FALSE)
    ids[[i]] <- rid
  }
  ids
}

old_names <- c(
  lens="lens_records_for_deduplication.jsonl",
  scopus="scopus_records_for_deduplication.jsonl",
  openalex="openalex_records_for_deduplication.jsonl",
  agricola="agricola_records_for_deduplication.jsonl",
  wos="wos_records_for_deduplication.jsonl"
)
current_paths <- c(
  lens=current_lens,
  scopus=current_scopus,
  openalex=current_openalex,
  agricola=current_agricola,
  wos=current_wos
)

summary_rows <- list()
old_total <- 0L
appended_total <- 0L

for (src in names(current_paths)) {
  old_lines <- character()
  old_ids <- character()
  if (src %in% names(old_names)) {
    hits <- list.files(old_dir,pattern=paste0("^",old_names[[src]],"$"),recursive=TRUE,full.names=TRUE)
    if (length(hits)!=1L) stop(sprintf("Expected exactly one preserved %s file, found %d",src,length(hits)),call.=FALSE)
    old_lines <- read_lines_nonempty(hits[[1L]])
    old_ids <- ids_for_lines(old_lines,src)
    if (anyDuplicated(old_ids)) stop(sprintf("Duplicate preserved %s source IDs",src),call.=FALSE)
  }

  cur_lines <- read_lines_nonempty(current_paths[[src]])
  cur_ids <- ids_for_lines(cur_lines,src)
  if (anyDuplicated(cur_ids)) stop(sprintf("Duplicate current %s source IDs",src),call.=FALSE)

  is_new <- !(cur_ids %in% old_ids)
  append_lines <- cur_lines[is_new]
  append_ids <- cur_ids[is_new]

  out_path <- file.path(output_dir,paste0(src,"_records_for_deduplication.jsonl"))
  con <- file(out_path,"wt",encoding="UTF-8")
  if (length(old_lines)) writeLines(old_lines,con,useBytes=TRUE)
  if (length(append_lines)) writeLines(append_lines,con,useBytes=TRUE)
  close(con)

  final_ids <- c(old_ids,append_ids)
  if (anyDuplicated(final_ids)) stop(sprintf("Union %s IDs are not unique",src),call.=FALSE)

  summary_rows[[length(summary_rows)+1L]] <- data.frame(
    source=src,
    preserved_old=length(old_ids),
    current_harvest=length(cur_ids),
    appended_new=length(append_ids),
    current_already_present=sum(!is_new),
    union_total=length(final_ids),
    stringsAsFactors=FALSE
  )
  old_total <- old_total + length(old_ids)
  appended_total <- appended_total + length(append_ids)
}

s <- do.call(rbind,summary_rows)
if (!is.na(expected_prior) && old_total != expected_prior) stop(sprintf("Preserved corpus should contain %d manifestations, found %d",expected_prior,old_total),call.=FALSE)
write.csv(s,file.path(output_dir,"union_source_counts.csv"),row.names=FALSE)
writeLines(toJSON(list(
  workflow="01_deduplication_incremental_union",
  status="success",
  preserved_prior_manifestations=old_total,
  appended_new_manifestations=appended_total,
  union_manifestations=old_total+appended_total,
  source_counts=split(s,s$source)
),auto_unbox=TRUE,pretty=TRUE,null="null"),
file.path(output_dir,"union_manifest.json"))
cat(sprintf("PASS: preserved %d prior manifestations and appended %d new manifestations; union=%d\n",
            old_total,appended_total,old_total+appended_total))
