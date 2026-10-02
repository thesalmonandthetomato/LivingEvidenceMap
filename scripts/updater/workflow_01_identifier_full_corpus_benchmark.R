#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(jsonlite)
  library(data.table)
})

`%||%` <- function(x,y) if (is.null(x)) y else x

args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag, default=NULL) {
  i <- match(flag,args)
  if (is.na(i)) return(default)
  if (i==length(args)) stop(sprintf("Missing value after %s",flag),call.=FALSE)
  args[[i+1L]]
}

metadata_path <- arg("--metadata")
cluster_path <- arg("--cluster-map")
lens_jsonl <- arg("--lens-jsonl")
openalex_raw <- arg("--openalex-raw-dir")
scopus_raw <- arg("--scopus-raw-dir")
wos_raw <- arg("--wos-raw-dir")
agricola_raw <- arg("--agricola-raw-dir")
output_dir <- arg("--output-dir")
prior_manifestations <- as.integer(arg("--prior-manifestations","90137"))

required <- c(metadata_path,cluster_path,lens_jsonl,openalex_raw,scopus_raw,wos_raw,agricola_raw,output_dir)
if (any(vapply(required,is.null,logical(1)))) stop("Missing required argument",call.=FALSE)
dir.create(output_dir,recursive=TRUE,showWarnings=FALSE)

norm_doi <- function(x) {
  if (is.null(x)||!length(x)) return(NULL)
  x <- as.character(x[[1L]])
  if (is.na(x)||!nzchar(trimws(x))) return(NULL)
  x <- tolower(trimws(x))
  x <- sub("^https?://(dx\\.)?doi\\.org/","",x,perl=TRUE)
  x <- sub("^doi:\\s*","",x,perl=TRUE)
  x <- sub("[.,;:]+$","",x,perl=TRUE)
  if (!nzchar(x)) NULL else x
}
norm_pmid <- function(x) {
  if (is.null(x)||!length(x)) return(NULL)
  x <- as.character(x[[1L]])
  if (is.na(x)||!nzchar(trimws(x))) return(NULL)
  x <- sub("^https?://pubmed\\.ncbi\\.nlm\\.nih\\.gov/","",x,ignore.case=TRUE)
  x <- sub("/$","",x)
  x <- gsub("[^0-9]","",x)
  if (!nzchar(x)) NULL else x
}
norm_pmcid <- function(x) {
  if (is.null(x)||!length(x)) return(NULL)
  x <- toupper(as.character(x[[1L]]))
  if (is.na(x)||!nzchar(trimws(x))) return(NULL)
  x <- sub("^https?://www\\.ncbi\\.nlm\\.nih\\.gov/pmc/articles/","",x,ignore.case=TRUE)
  x <- sub("/$","",x)
  x <- gsub("[^A-Z0-9]","",x)
  if (!startsWith(x,"PMC")) x <- paste0("PMC",x)
  if (!grepl("^PMC[0-9]+$",x)) return(NULL)
  x
}
norm_openalex <- function(x) {
  if (is.null(x)||!length(x)) return(NULL)
  x <- toupper(as.character(x[[1L]]))
  if (is.na(x)||!nzchar(trimws(x))) return(NULL)
  x <- sub("^https?://openalex\\.org/","",x,ignore.case=TRUE)
  if (!grepl("^W[0-9]+$",x)) return(NULL)
  x
}
norm_mag <- function(x) {
  if (is.null(x)||!length(x)) return(NULL)
  x <- gsub("[^0-9]","",as.character(x[[1L]]))
  if (!nzchar(x)) NULL else x
}
norm_core <- function(x) {
  if (is.null(x)||!length(x)) return(NULL)
  x <- as.character(x[[1L]])
  if (is.na(x)||!nzchar(trimws(x))) return(NULL)
  x <- sub("^https?://core\\.ac\\.uk/(works/)?","",x,ignore.case=TRUE)
  x <- sub("^core[: ]*","",x,ignore.case=TRUE)
  x <- trimws(x)
  if (!nzchar(x)) NULL else x
}
normalise <- function(ns,value) {
  ns <- tolower(trimws(as.character(ns)))
  aliases <- c(doi="doi",pmid="pmid",pubmed="pmid",pubmed_id="pmid",`pubmed-id`="pmid",
               pmcid="pmcid",pmc="pmcid",openalex="openalex",openalex_id="openalex",
               mag="mag",magid="mag",mag_id="mag",core="core",coreid="core",core_id="core")
  if (!(ns %in% names(aliases))) return(NULL)
  ns <- unname(aliases[[ns]])
  v <- switch(ns,doi=norm_doi(value),pmid=norm_pmid(value),pmcid=norm_pmcid(value),
              openalex=norm_openalex(value),mag=norm_mag(value),core=norm_core(value),NULL)
  if (is.null(v)) NULL else list(namespace=ns,value=v)
}

meta <- fread(metadata_path,na.strings=c("","NA"))
clusters <- fread(cluster_path,na.strings=c("","NA"))
setkeyv(meta,c("source","source_record_id"))
setkeyv(clusters,c("source","source_record_id"))
meta <- clusters[meta,on=.(source,source_record_id)]
meta[, manifestation_key:=paste(source,source_record_id,sep="::")]
valid_keys <- meta$manifestation_key

registry <- list()
add_id <- function(key,source,ns,value) {
  if (!(key %chin% valid_keys)) return(invisible(NULL))
  z <- normalise(ns,value)
  if (is.null(z)) return(invisible(NULL))
  registry[[length(registry)+1L]] <<- data.table(
    manifestation_key=key,source=source,
    identifier_type=z$namespace,identifier_value=z$value
  )
}

# DOI baseline from W01 normalised metadata.
for (i in which(!is.na(meta$doi_norm) & nzchar(meta$doi_norm))) {
  add_id(meta$manifestation_key[[i]],meta$source[[i]],"doi",meta$doi_norm[[i]])
}

# Lens full JSONL.
con <- file(lens_jsonl,"rt",encoding="UTF-8")
repeat {
  lines <- readLines(con,n=500L,warn=FALSE)
  if (!length(lines)) break
  for (line in lines[nzchar(trimws(lines))]) {
    r <- fromJSON(line,simplifyVector=FALSE)
    rid <- as.character(r$identity$lens_id %||% r$identity$record_id %||% "")
    key <- paste("lens",rid,sep="::")
    ext <- r$lens$raw_payload$external_ids %||% list()
    for (z in ext) if (is.list(z)) add_id(key,"lens",z$type %||% "",z$value)
  }
}
close(con)

# Generic JSON page iterator.
json_files <- function(path) sort(list.files(path,pattern="response_[0-9]+\\.json$",full.names=TRUE))

# OpenAlex.
for (p in json_files(openalex_raw)) {
  x <- fromJSON(p,simplifyVector=FALSE)
  for (w in x$results %||% list()) {
    oid <- sub("^https?://openalex\\.org/","",as.character(w$id %||% ""),ignore.case=TRUE)
    key <- paste("openalex",paste0("openalex:",oid),sep="::")
    ids <- w$ids %||% list()
    for (nm in names(ids)) add_id(key,"openalex",nm,ids[[nm]])
    add_id(key,"openalex","openalex",w$id)
    add_id(key,"openalex","doi",w$doi)
  }
}

# Scopus.
for (p in json_files(scopus_raw)) {
  x <- fromJSON(p,simplifyVector=FALSE)
  entries <- x[["search-results"]][["entry"]] %||% list()
  for (e in entries) {
    eid <- as.character(e$eid %||% "")
    key <- paste("scopus",paste0("scopus:",eid),sep="::")
    add_id(key,"scopus","doi",e[["prism:doi"]])
    add_id(key,"scopus","pmid",e[["pubmed-id"]])
  }
}

# Web of Science.
for (p in json_files(wos_raw)) {
  x <- fromJSON(p,simplifyVector=FALSE)
  for (e in x$hits %||% list()) {
    uid <- as.character(e$uid %||% "")
    key <- paste("wos",paste0("wos:",uid),sep="::")
    ids <- e$identifiers %||% list()
    for (nm in c("doi","pmid","pmcid")) add_id(key,"wos",nm,ids[[nm]])
  }
}

# AGRICOLA through Europe PMC.
for (p in json_files(agricola_raw)) {
  x <- fromJSON(p,simplifyVector=FALSE)
  records <- x$resultList$result %||% list()
  for (e in records) {
    rid <- as.character(e$id %||% "")
    key <- paste("agricola",paste0("agricola:",rid),sep="::")
    for (nm in c("doi","pmid","pmcid")) add_id(key,"agricola",nm,e[[nm]])
  }
}

reg <- unique(rbindlist(registry,use.names=TRUE,fill=TRUE))
fwrite(reg,file.path(output_dir,"identifier_registry.csv"))

coverage <- reg[,.(manifestations=uniqueN(manifestation_key)),by=.(source,identifier_type)]
fwrite(coverage,file.path(output_dir,"identifier_coverage_by_source.csv"))

groups <- reg[,.(n_manifestations=uniqueN(manifestation_key),n_sources=uniqueN(source)),
              by=.(identifier_type,identifier_value)]
shared <- groups[n_manifestations>1L & n_sources>1L]
fwrite(shared,file.path(output_dir,"shared_identifier_groups.csv"))

shared_reg <- reg[shared,on=.(identifier_type,identifier_value),nomatch=0L]
pair_chunks <- list()
for (k in seq_len(nrow(shared))) {
  z <- shared_reg[identifier_type==shared$identifier_type[[k]] &
                  identifier_value==shared$identifier_value[[k]]]
  keys <- sort(unique(z$manifestation_key))
  if (length(keys)<2L) next
  cmb <- combn(keys,2L)
  tmp <- data.table(record_i=cmb[1,],record_j=cmb[2,],
                    identifier_type=shared$identifier_type[[k]],
                    identifier_value=shared$identifier_value[[k]])
  tmp <- tmp[tstrsplit(record_i,"::",fixed=TRUE,keep=1L) !=
             tstrsplit(record_j,"::",fixed=TRUE,keep=1L)]
  if (nrow(tmp)) pair_chunks[[length(pair_chunks)+1L]] <- tmp
}
raw_pairs <- if(length(pair_chunks)) unique(rbindlist(pair_chunks)) else
  data.table(record_i=character(),record_j=character(),identifier_type=character(),identifier_value=character())

pair_ev <- raw_pairs[,.(namespaces=paste(sort(unique(identifier_type)),collapse="|")),
                     by=.(record_i,record_j)]
pair_ev[, families:=vapply(strsplit(namespaces,"\\|"),function(z) {
  z[z %in% c("openalex","mag")] <- "openalex_mag"
  paste(sort(unique(z)),collapse="|")
},character(1))]
pair_ev[, n_independent_families:=lengths(strsplit(families,"\\|"))]

lookup <- meta[,.(manifestation_key,idx,cluster_id,title_norm,year)]
setkey(lookup,manifestation_key)
pair_ev <- lookup[pair_ev,on=.(manifestation_key=record_i)]
setnames(pair_ev,c("idx","cluster_id","title_norm","year"),
         c("idx_i","cluster_i","title_i","year_i"))
pair_ev <- lookup[pair_ev,on=.(manifestation_key=record_j)]
setnames(pair_ev,c("idx","cluster_id","title_norm","year"),
         c("idx_j","cluster_j","title_j","year_j"))
pair_ev[, same_cluster:=cluster_i==cluster_j]
pair_ev[, title_exact:=!is.na(title_i)&!is.na(title_j)&title_i==title_j]
pair_ev[, year_diff:=ifelse(!is.na(year_i)&!is.na(year_j),abs(year_i-year_j),NA_real_)]
pair_ev[, involves_appended:=idx_i>prior_manifestations | idx_j>prior_manifestations]

fwrite(pair_ev,file.path(output_dir,"identifier_candidate_pairs.csv"))
disagree <- pair_ev[same_cluster==FALSE]
fwrite(disagree,file.path(output_dir,"different_cluster_identifier_pairs.csv"))

summary <- list(
  schema="living-evidence-map-w01-full-identifier-benchmark-v1",
  status="success",
  test_only=TRUE,
  manifestations=nrow(meta),
  manifestations_with_any_identifier=uniqueN(reg$manifestation_key),
  identifier_rows=nrow(reg),
  identifier_rows_by_namespace=as.list(reg[,.N,by=identifier_type][,setNames(as.list(N),identifier_type)]),
  manifestations_by_namespace=as.list(reg[,.(N=uniqueN(manifestation_key)),by=identifier_type][,setNames(as.list(N),identifier_type)]),
  cross_source_shared_groups=nrow(shared),
  shared_groups_by_namespace=as.list(shared[,.N,by=identifier_type][,setNames(as.list(N),identifier_type)]),
  candidate_pairs=nrow(pair_ev),
  pairs_same_existing_cluster=sum(pair_ev$same_cluster),
  pairs_different_existing_cluster=sum(!pair_ev$same_cluster),
  pairs_same_cluster_percent=round(100*mean(pair_ev$same_cluster),4),
  pairs_with_multiple_independent_families=sum(pair_ev$n_independent_families>=2L),
  incremental_pairs_involving_appended=sum(pair_ev$involves_appended),
  incremental_pairs_same_cluster=sum(pair_ev$involves_appended & pair_ev$same_cluster),
  incremental_pairs_different_cluster=sum(pair_ev$involves_appended & !pair_ev$same_cluster),
  automatic_merges_performed=0L,
  production_w01_modified=FALSE,
  note="Read-only benchmark against saved W01 output. Identifier pairs are evidence only."
)
writeLines(toJSON(summary,auto_unbox=TRUE,pretty=TRUE,null="null",na="null"),
           file.path(output_dir,"summary.json"))
cat(sprintf("PASS: full identifier benchmark: %d manifestations, %d candidate pairs, %.3f%% already same W01 cluster, zero merges\n",
            nrow(meta),nrow(pair_ev),100*mean(pair_ev$same_cluster)))
