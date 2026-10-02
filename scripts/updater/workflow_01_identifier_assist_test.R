#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(jsonlite)
  library(data.table)
  library(stringi)
})

`%||%` <- function(x,y) if (is.null(x)) y else x

args <- commandArgs(trailingOnly=TRUE)
arg_one <- function(flag,default=NULL) {
  i <- match(flag,args)
  if (is.na(i)) return(default)
  if (i==length(args)) stop(sprintf("Missing value after %s",flag),call.=FALSE)
  args[[i+1L]]
}
input_manifest <- arg_one("--input-manifest")
metadata_path <- arg_one("--metadata")
output_dir <- arg_one("--output-dir")
if (is.null(output_dir) || (is.null(input_manifest) && is.null(metadata_path)) || (!is.null(input_manifest) && !is.null(metadata_path))) {
  stop("Required: --output-dir and exactly one of --input-manifest or --metadata",call.=FALSE)
}
if (!is.null(input_manifest) && !file.exists(input_manifest)) stop("Input manifest not found",call.=FALSE)
if (!is.null(metadata_path) && !file.exists(metadata_path)) stop("Metadata file not found",call.=FALSE)
dir.create(output_dir,recursive=TRUE,showWarnings=FALSE)

manifest <- NULL
if (!is.null(input_manifest)) {
  manifest <- fromJSON(input_manifest,simplifyVector=FALSE)
  if (!identical(manifest$schema,"living-evidence-map-workflow01-source-inputs-v1")) {
    stop("Unsupported W01 source-input manifest schema",call.=FALSE)
  }
  if (is.null(manifest$sources) || !length(manifest$sources) || is.null(names(manifest$sources))) {
    stop("Source-input manifest contains no named sources",call.=FALSE)
  }
}

scalar <- function(x) {
  if (is.null(x) || !length(x)) return(NULL)
  y <- trimws(as.character(x[[1L]]))
  if (!nzchar(y)) NULL else y
}
norm_doi <- function(x) {
  x <- scalar(x)
  if (is.null(x)) return(NULL)
  x <- tolower(trimws(x))
  x <- sub("^https?://(dx\\.)?doi\\.org/","",x,perl=TRUE)
  x <- sub("^doi:\\s*","",x,perl=TRUE)
  x <- sub("[?#].*$","",x,perl=TRUE)
  x <- sub("/full/html?$","",x,perl=TRUE,ignore.case=TRUE)
  x <- sub("\\.(html?|pdf|xml)$","",x,perl=TRUE,ignore.case=TRUE)
  x <- sub("[.,;:]+$","",x,perl=TRUE)
  if (!nzchar(x)) NULL else x
}
norm_pmid <- function(x) {
  x <- scalar(x)
  if (is.null(x)) return(NULL)
  x <- sub("^PMID[: ]*","",toupper(x))
  x <- gsub("[^0-9]","",x)
  if (!nzchar(x)) NULL else x
}
norm_pmcid <- function(x) {
  x <- scalar(x)
  if (is.null(x)) return(NULL)
  x <- toupper(gsub("[^A-Za-z0-9]","",x))
  if (!startsWith(x,"PMC")) x <- paste0("PMC",x)
  if (!grepl("^PMC[0-9]+$",x)) return(NULL)
  x
}
norm_title <- function(x) {
  x <- scalar(x)
  if (is.null(x)) return(NULL)
  x <- stri_trans_tolower(stri_trans_nfkc(x))
  x <- stri_replace_all_regex(x,"[\\p{P}\\p{S}\\p{Z}\\s]+","")
  if (!nzchar(x)) NULL else x
}
record_year <- function(r) {
  z <- scalar((r$mapped_fields %||% list())$year %||%
              (r$mapped_fields %||% list())$publication_date)
  if (is.null(z)) return(NA_integer_)
  m <- regexpr("(19|20)[0-9]{2}",z,perl=TRUE)
  if (m[[1L]]<0L) NA_integer_ else as.integer(regmatches(z,m))
}
source_record_id <- function(r) {
  if (is.list(r$lens)) {
    return(as.character((r$identity %||% list())$lens_id %||%
                        (r$identity %||% list())$record_id %||% ""))
  }
  as.character((r$sidecar_identity %||% list())$sidecar_record_id %||% "")
}
source_kind <- function(r,expected) {
  if (is.list(r$lens)) return("lens")
  p <- scalar((r$source %||% list())$provider)
  if (is.null(p)) return(expected)
  if (identical(p,"wos_starter")) return("wos")
  if (identical(p,"agricola_via_europe_pmc")) return("agricola")
  p
}

extract_ids <- function(r,source) {
  out <- list()
  add <- function(type,value) {
    if (is.null(value) || !nzchar(value)) return()
    out[[length(out)+1L]] <<- list(type=type,value=value)
  }

  doi <- norm_doi(
    (r$mapped_fields %||% list())$doi %||%
    (r$sidecar_identity %||% list())$doi %||%
    (r$canonical %||% list())$doi
  )
  add("doi",doi)

  pmid <- norm_pmid(
    (r$mapped_fields %||% list())$pmid %||%
    (r$sidecar_identity %||% list())$pmid %||%
    (r$identity %||% list())$pmid %||%
    (r$canonical %||% list())$pmid
  )
  if (is.null(pmid) && identical(source,"pubmed")) {
    epmc_source <- scalar((r$sidecar_identity %||% list())$europe_pmc_source)
    epmc_id <- scalar((r$sidecar_identity %||% list())$europe_pmc_id)
    if (identical(epmc_source,"MED")) pmid <- norm_pmid(epmc_id)
  }
  if (is.null(pmid) && is.list(r$europe_pmc$raw_payload)) {
    pmid <- norm_pmid(r$europe_pmc$raw_payload$pmid)
  }
  add("pmid",pmid)

  pmcid <- norm_pmcid(
    (r$mapped_fields %||% list())$pmcid %||%
    (r$sidecar_identity %||% list())$pmcid %||%
    (r$canonical %||% list())$pmcid
  )
  if (is.null(pmcid) && is.list(r$europe_pmc$raw_payload)) {
    pmcid <- norm_pmcid(r$europe_pmc$raw_payload$pmcid)
  }
  add("pmcid",pmcid)

  out
}

read_jsonl <- function(path,source,fun) {
  if (!file.exists(path)) stop(sprintf("Source input not found: %s",path),call.=FALSE)
  con <- file(path,"rt",encoding="UTF-8")
  on.exit(close(con),add=TRUE)
  n <- 0L
  repeat {
    z <- readLines(con,n=500L,warn=FALSE)
    if (!length(z)) break
    for (line in z) {
      if (!nzchar(trimws(line))) next
      n <- n+1L
      fun(fromJSON(line,simplifyVector=FALSE),source,n)
    }
  }
  n
}

manifestations <- list()
identifiers <- list()
source_counts <- integer()

if (!is.null(metadata_path)) {
  meta <- fread(metadata_path,na.strings=c("","NA"))
  required <- c("idx","source","source_record_id","doi_norm","title_norm","year")
  miss <- setdiff(required,names(meta))
  if (length(miss)) stop(sprintf("Metadata missing required columns: %s",paste(miss,collapse=", ")),call.=FALSE)
  m <- meta[,.(manifestation_key=paste(source,source_record_id,sep="::"),
               source,source_record_id,title_norm,year)]
  if (anyDuplicated(m$manifestation_key)) stop("Duplicate manifestation keys in metadata",call.=FALSE)
  source_counts <- table(meta$source)
  id <- meta[!is.na(doi_norm) & nzchar(doi_norm),
             .(manifestation_key=paste(source,source_record_id,sep="::"),
               source,identifier_type="doi",identifier_value=doi_norm)]
  id <- unique(id)
} else {
  source_paths <- vapply(manifest$sources,function(z) as.character(z$path %||% z),character(1))
  for (src in names(source_paths)) {
    source_counts[[src]] <- read_jsonl(source_paths[[src]],src,function(r,expected,i) {
      actual <- source_kind(r,expected)
      rid <- source_record_id(r)
      if (!nzchar(rid)) stop(sprintf("%s record %d lacks source_record_id",expected,i),call.=FALSE)
      key <- paste(expected,rid,sep="::")
      ttl <- scalar((r$mapped_fields %||% list())$title %||% (r$canonical %||% list())$title)
      manifestations[[length(manifestations)+1L]] <<- data.table(
        manifestation_key=key,
        source=expected,
        source_record_id=rid,
        title_norm=norm_title(ttl) %||% NA_character_,
        year=record_year(r)
      )
      ids <- extract_ids(r,expected)
      if (length(ids)) {
        for (id0 in ids) identifiers[[length(identifiers)+1L]] <<- data.table(
          manifestation_key=key,
          source=expected,
          identifier_type=id0$type,
          identifier_value=id0$value
        )
      }
    })
  }
  m <- if (length(manifestations)) rbindlist(manifestations,use.names=TRUE,fill=TRUE) else data.table()
  id <- if (length(identifiers)) rbindlist(identifiers,use.names=TRUE,fill=TRUE) else
    data.table(manifestation_key=character(),source=character(),identifier_type=character(),identifier_value=character())
  if (nrow(m) && anyDuplicated(m$manifestation_key)) stop("Duplicate manifestation keys in inputs",call.=FALSE)
  if (nrow(id)) id <- unique(id)
}

fwrite(id,file.path(output_dir,"cross_source_identifiers.csv"))

shared <- if (nrow(id)) id[,.(n_manifestations=uniqueN(manifestation_key),
                              n_sources=uniqueN(source)),
                           by=.(identifier_type,identifier_value)][n_manifestations>1L & n_sources>1L] else
  data.table(identifier_type=character(),identifier_value=character(),n_manifestations=integer(),n_sources=integer())
fwrite(shared,file.path(output_dir,"shared_identifier_groups.csv"))

pairs <- list()
if (nrow(shared)) {
  for (k in seq_len(nrow(shared))) {
    z <- id[identifier_type==shared$identifier_type[[k]] &
            identifier_value==shared$identifier_value[[k]],
            unique(manifestation_key)]
    if (length(z)<2L) next
    cmb <- combn(sort(z),2L)
    pairs[[length(pairs)+1L]] <- data.table(
      record_i=cmb[1,],
      record_j=cmb[2,],
      identifier_type=shared$identifier_type[[k]],
      identifier_value=shared$identifier_value[[k]]
    )
  }
}
p <- if (length(pairs)) rbindlist(pairs) else
  data.table(record_i=character(),record_j=character(),identifier_type=character(),identifier_value=character())

if (nrow(p)) {
  p[, pair_key:=paste(record_i,record_j,sep="::")]
  evidence <- p[,.(shared_identifier_types=paste(sort(unique(identifier_type)),collapse="|"),
                   shared_identifier_values=paste(sort(unique(paste(identifier_type,identifier_value,sep=":"))),collapse="|")),
                by=.(pair_key,record_i,record_j)]
  mi <- m[match(evidence$record_i,manifestation_key)]
  mj <- m[match(evidence$record_j,manifestation_key)]
  evidence[, title_exact:=!is.na(mi$title_norm) & !is.na(mj$title_norm) & mi$title_norm==mj$title_norm]
  evidence[, year_compatible:=is.na(mi$year) | is.na(mj$year) | abs(mi$year-mj$year)<=1L]
  evidence[, metadata_conflict:=(!is.na(mi$year) & !is.na(mj$year) & abs(mi$year-mj$year)>1L)]
  fwrite(evidence,file.path(output_dir,"identifier_candidate_pairs.csv"))
} else {
  evidence <- data.table(
    pair_key=character(),record_i=character(),record_j=character(),
    shared_identifier_types=character(),shared_identifier_values=character(),
    title_exact=logical(),year_compatible=logical(),metadata_conflict=logical()
  )
  fwrite(evidence,file.path(output_dir,"identifier_candidate_pairs.csv"))
}

summary <- list(
  schema="living-evidence-map-workflow01-identifier-assist-test-v1",
  status="success",
  test_only=TRUE,
  automatic_merges_performed=0L,
  existing_w01_files_modified=FALSE,
  input_manifest=input_manifest,
  metadata_path=metadata_path,
  manifestations=nrow(m),
  sources=as.list(source_counts),
  identifier_rows=nrow(id),
  identifier_counts=if(nrow(id)) as.list(id[,.N,by=identifier_type][,setNames(as.list(N),identifier_type)]) else list(),
  cross_source_shared_identifier_groups=nrow(shared),
  identifier_candidate_pairs=nrow(evidence),
  candidate_pairs_with_year_conflict=if(nrow(evidence)) sum(evidence$metadata_conflict) else 0L,
  note="This test emits candidate evidence only. It does not merge, remove, recluster, or alter W01 records."
)
writeLines(toJSON(summary,auto_unbox=TRUE,pretty=TRUE,null="null",na="null"),
           file.path(output_dir,"summary.json"))

cat(sprintf("PASS: identifier-assist test emitted %d candidate pairs from %d manifestations; zero merges performed\n",
            nrow(evidence),nrow(m)))
