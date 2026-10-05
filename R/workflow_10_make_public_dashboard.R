#!/usr/bin/env Rscript
suppressPackageStartupMessages({library(jsonlite);library(digest)})

args <- commandArgs(trailingOnly=TRUE)
input_js <- if(length(args)>=1L) args[[1L]] else stop("Missing internal dashboard JS path",call.=FALSE)
output_js <- if(length(args)>=2L) args[[2L]] else stop("Missing public dashboard JS path",call.=FALSE)

if(!file.exists(input_js)) stop(sprintf("Input dashboard JS not found: %s",input_js),call.=FALSE)
txt <- paste(readLines(input_js,warn=FALSE,encoding="UTF-8"),collapse="\n")
prefix <- "window.LIVING_EVIDENCE_MAP_DASHBOARD_DATA="
if(!startsWith(txt,prefix) || !endsWith(txt,";")) stop("Input dashboard JS has unexpected wrapper",call.=FALSE)
payload <- fromJSON(substr(txt,nchar(prefix)+1L,nchar(txt)-1L),simplifyVector=FALSE)

records <- payload$records
if(!is.list(records)) stop("Input dashboard payload has no record list",call.=FALSE)

public_records <- lapply(records,function(r){
  list(
    year=r$year,
    species=r$species,
    iso3=r$iso3,
    topic_paths=r$topic_paths
  )
})

payload$records <- public_records
payload$public_projection <- list(
  schema="living-evidence-map-workflow10-public-dashboard-v1",
  record_level_identifiers=FALSE,
  titles=FALSE,
  abstracts=FALSE,
  citation_metadata=FALSE,
  search_index=FALSE
)

forbidden <- c("record_id","title","abstract","doi","authors","journal","volume","pages","lens_url")
bad <- unique(unlist(lapply(public_records,function(r)intersect(names(r),forbidden)),use.names=FALSE))
if(length(bad)) stop(sprintf("Forbidden public record fields remain: %s",paste(bad,collapse=", ")),call.=FALSE)

dir.create(dirname(output_js),recursive=TRUE,showWarnings=FALSE)
writeLines(
  paste0(prefix,toJSON(payload,auto_unbox=TRUE,null="null",na="null",pretty=FALSE),";"),
  output_js,useBytes=TRUE
)

# Validate forbidden fields structurally within public record objects only.
# Top-level provenance may legitimately contain identifiers such as the source DOI.
roundtrip <- fromJSON(
  substr(
    paste(readLines(output_js,warn=FALSE,encoding="UTF-8"),collapse="\n"),
    nchar(prefix)+1L,
    nchar(paste(readLines(output_js,warn=FALSE,encoding="UTF-8"),collapse="\n"))-1L
  ),
  simplifyVector=FALSE
)
forbidden <- c("record_id","title","abstract","doi","authors","journal","volume","pages","lens_url")
if(!is.list(roundtrip$records) || length(roundtrip$records)!=length(public_records)) {
  stop("Public dashboard round-trip record structure is invalid",call.=FALSE)
}
bad_fields <- unique(unlist(lapply(roundtrip$records,function(r)intersect(names(r),forbidden)),use.names=FALSE))
if(length(bad_fields)) {
  stop(sprintf("Forbidden public record fields remain: %s",paste(bad_fields,collapse=", ")),call.=FALSE)
}

cat(sprintf(
  "PASS: public W10 projection contains %d anonymous chart records; SHA-256 %s\n",
  length(public_records),digest(file=output_js,algo="sha256",serialize=FALSE)
))
