#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(jsonlite)
  library(digest)
})

args <- commandArgs(trailingOnly=TRUE)

values_after <- function(flag) {
  which(args == flag)
}
arg_one <- function(flag, default=NULL) {
  i <- match(flag,args)
  if (is.na(i)) return(default)
  if (i == length(args)) stop(sprintf("Missing value after %s",flag),call.=FALSE)
  args[[i+1L]]
}

input_pos <- values_after("--input")
if (!length(input_pos)) stop("At least one --input source=path is required",call.=FALSE)
inputs <- vapply(input_pos,function(i) {
  if (i == length(args)) stop("Missing value after --input",call.=FALSE)
  args[[i+1L]]
},character(1))
if (any(!grepl("^[^=]+=",inputs))) stop("Each --input must be source=path",call.=FALSE)
source_names <- sub("=.*$","",inputs)
input_paths <- sub("^[^=]+=","",inputs)
if (anyDuplicated(source_names)) stop("Each source may be supplied only once",call.=FALSE)

prior_registry <- arg_one("--prior-registry",NULL)
output_dir <- arg_one("--output-dir")
if (is.null(output_dir)) stop("--output-dir is required",call.=FALSE)
dir.create(output_dir,recursive=TRUE,showWarnings=FALSE)

`%||%` <- function(x,y) if (is.null(x)) y else x
scalar <- function(x) {
  if (is.null(x) || !length(x)) return(NULL)
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
  if (src == "lens") {
    return(as.character((r$identity %||% list())$lens_id %||%
                        (r$identity %||% list())$record_id %||% ""))
  }
  as.character((r$sidecar_identity %||% list())$sidecar_record_id %||% "")
}
read_nonempty <- function(path) {
  if (!file.exists(path)) stop(sprintf("Input not found: %s",path),call.=FALSE)
  x <- readLines(path,warn=FALSE,encoding="UTF-8")
  x[nzchar(trimws(x))]
}
write_jsonl <- function(lines,path) {
  con <- file(path,"wt",encoding="UTF-8")
  on.exit(close(con),add=TRUE)
  if (length(lines)) writeLines(lines,con,useBytes=TRUE)
}

prior <- data.frame(source=character(),source_record_id=character(),stringsAsFactors=FALSE)
if (!is.null(prior_registry) && nzchar(prior_registry)) {
  if (!file.exists(prior_registry)) stop(sprintf("Prior registry not found: %s",prior_registry),call.=FALSE)
  prior <- read.csv(prior_registry,stringsAsFactors=FALSE,check.names=FALSE)
  required <- c("source","source_record_id")
  if (!all(required %in% names(prior))) stop("Prior registry must contain source and source_record_id",call.=FALSE)
  prior <- prior[!is.na(prior$source) & !is.na(prior$source_record_id) &
                 nzchar(prior$source) & nzchar(prior$source_record_id),required,drop=FALSE]
  prior_key <- paste(prior$source,prior$source_record_id,sep="::")
  if (anyDuplicated(prior_key)) stop("Prior registry contains duplicate source/source_record_id keys",call.=FALSE)
}
prior_keys <- if (nrow(prior)) paste(prior$source,prior$source_record_id,sep="::") else character()

summary_rows <- list()
delta_rows <- list()
conflict_rows <- list()
promoted_total <- 0L

for (k in seq_along(input_paths)) {
  expected_source <- source_names[[k]]
  lines <- read_nonempty(input_paths[[k]])
  ids <- character(length(lines))
  hashes <- character(length(lines))

  for (i in seq_along(lines)) {
    r <- fromJSON(lines[[i]],simplifyVector=FALSE)
    src <- source_kind(r)
    if (!identical(src,expected_source)) {
      stop(sprintf("Expected source %s but found %s at line %d",expected_source,src,i),call.=FALSE)
    }
    rid <- source_record_id(r)
    if (!nzchar(rid)) stop(sprintf("%s line %d lacks source_record_id",expected_source,i),call.=FALSE)
    ids[[i]] <- rid
    hashes[[i]] <- digest(lines[[i]],algo="sha256",serialize=FALSE)
  }

  duplicate_ids <- unique(ids[duplicated(ids) | duplicated(ids,fromLast=TRUE)])
  keep <- rep(TRUE,length(lines))
  exact_duplicate_rows <- 0L

  for (rid in duplicate_ids) {
    ix <- which(ids == rid)
    unique_hashes <- unique(hashes[ix])
    if (length(unique_hashes) > 1L) {
      conflict_rows[[length(conflict_rows)+1L]] <- data.frame(
        source=expected_source,
        source_record_id=rid,
        occurrences=length(ix),
        distinct_payload_hashes=length(unique_hashes),
        stringsAsFactors=FALSE
      )
      next
    }
    keep[ix[-1L]] <- FALSE
    exact_duplicate_rows <- exact_duplicate_rows + length(ix) - 1L
  }

  if (length(conflict_rows)) next

  unique_lines <- lines[keep]
  unique_ids <- ids[keep]
  keys <- paste(expected_source,unique_ids,sep="::")
  known <- keys %in% prior_keys
  promoted_lines <- unique_lines[!known]
  promoted_ids <- unique_ids[!known]

  out <- file.path(output_dir,paste0(expected_source,"_promoted_new_records.jsonl"))
  write_jsonl(promoted_lines,out)

  if (length(promoted_ids)) {
    delta_rows[[length(delta_rows)+1L]] <- data.frame(
      source=expected_source,
      source_record_id=promoted_ids,
      status="new",
      stringsAsFactors=FALSE
    )
  }

  summary_rows[[length(summary_rows)+1L]] <- data.frame(
    source=expected_source,
    harvested_rows=length(lines),
    unique_source_ids=length(unique_ids),
    exact_duplicate_rows_removed=exact_duplicate_rows,
    already_known=sum(known),
    promoted_new=sum(!known),
    stringsAsFactors=FALSE
  )
  promoted_total <- promoted_total + sum(!known)
}

if (length(conflict_rows)) {
  conflicts <- do.call(rbind,conflict_rows)
  write.csv(conflicts,file.path(output_dir,"within_source_id_conflicts.csv"),row.names=FALSE)
  stop(sprintf("Conflicting payloads found for %d repeated source_record_id values; refusing to choose a manifestation",
               nrow(conflicts)),call.=FALSE)
}

summary_df <- if (length(summary_rows)) do.call(rbind,summary_rows) else data.frame()
delta_df <- if (length(delta_rows)) do.call(rbind,delta_rows) else
  data.frame(source=character(),source_record_id=character(),status=character())

write.csv(summary_df,file.path(output_dir,"source_identity_summary.csv"),row.names=FALSE)
write.csv(delta_df,file.path(output_dir,"promoted_manifestation_registry_delta.csv"),row.names=FALSE)
writeLines(toJSON(list(
  workflow="01_source_identity_filter",
  status="success",
  prior_registry_rows=nrow(prior),
  promoted_new_manifestations=promoted_total,
  sources=if (nrow(summary_df)) split(summary_df,summary_df$source) else list()
),auto_unbox=TRUE,pretty=TRUE,null="null"),
file.path(output_dir,"source_identity_manifest.json"))

cat(sprintf("PASS: source-ID filtering complete; %d novel manifestations promoted\n",promoted_total))
