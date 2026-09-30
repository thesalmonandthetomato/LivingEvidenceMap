#!/usr/bin/env Rscript
suppressPackageStartupMessages({library(jsonlite);library(digest)})

args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag,default=NULL){i<-match(flag,args);if(is.na(i))return(default);if(i==length(args))stop(sprintf("Missing value after %s",flag),call.=FALSE);args[[i+1L]]}
assembled_path <- arg("--assembled")
old_manifest_path <- arg("--old-manifest")
canonical_out <- arg("--canonical-output")
exclusions_out <- arg("--exclusions-output")
manifest_out <- arg("--manifest-output")
if(any(vapply(list(assembled_path,old_manifest_path,canonical_out,exclusions_out,manifest_out),is.null,logical(1)))) stop("Required Workflow 08 partition arguments missing",call.=FALSE)
for(p in c(assembled_path,old_manifest_path)) if(!file.exists(p)) stop("Missing input: ",p,call.=FALSE)

`%||%` <- function(x,y) if(is.null(x)||length(x)==0L) y else x
clean <- function(x){z<-as.character(x %||% "");if(length(z)==0L||is.na(z[[1L]]))"" else z[[1L]]}
dir.create(dirname(canonical_out),recursive=TRUE,showWarnings=FALSE)
dir.create(dirname(exclusions_out),recursive=TRUE,showWarnings=FALSE)
dir.create(dirname(manifest_out),recursive=TRUE,showWarnings=FALSE)

inc_con <- file(canonical_out,"wt",encoding="UTF-8")
on.exit(close(inc_con),add=TRUE)
in_con <- file(assembled_path,"rt",encoding="UTF-8")
on.exit(close(in_con),add=TRUE)

excluded_rows <- list()
n <- 0L; included <- 0L; excluded <- 0L
repeat{
  ln <- readLines(in_con,n=1L,warn=FALSE)
  if(!length(ln)) break
  if(!nzchar(trimws(ln))) next
  rec <- fromJSON(ln,simplifyVector=FALSE)
  n <- n + 1L
  scr <- rec$screening %||% list()
  if(isTRUE(scr$final_included)){
    writeLines(toJSON(rec,auto_unbox=TRUE,null="null",na="null",digits=NA),inc_con,useBytes=TRUE)
    included <- included + 1L
  } else {
    excluded <- excluded + 1L
    can <- rec$canonical %||% list()
    id <- rec$identity %||% list()
    excluded_rows[[length(excluded_rows)+1L]] <- data.frame(
      record_id=clean(id$record_id),
      title=clean(can$title),
      authors=clean(can$authors),
      year=clean(can$year),
      journal=clean(can$journal),
      volume=clean(can$volume),
      issue=clean(can$issue),
      pages=clean(can$pages),
      doi=clean(can$doi),
      exclusion_stage=clean(scr$exclusion_stage),
      exclusion_reason=clean(scr$exclusion_reason),
      stringsAsFactors=FALSE
    )
  }
}
close(in_con);on.exit(NULL,add=FALSE)
close(inc_con);on.exit(NULL,add=FALSE)

if(included+excluded!=n) stop(sprintf("Partition accounting mismatch: total=%d included=%d excluded=%d",n,included,excluded),call.=FALSE)

ex <- if(excluded) do.call(rbind,excluded_rows) else data.frame(
  record_id=character(),title=character(),authors=character(),year=character(),journal=character(),
  volume=character(),issue=character(),pages=character(),doi=character(),
  exclusion_stage=character(),exclusion_reason=character(),stringsAsFactors=FALSE
)
if(anyDuplicated(ex$record_id)||any(!nzchar(ex$record_id))) stop("Invalid excluded-record IDs",call.=FALSE)
write.csv(ex,exclusions_out,row.names=FALSE,na="",fileEncoding="UTF-8",quote=TRUE)

old <- fromJSON(old_manifest_path,simplifyVector=FALSE)
if(!identical(old$status,"PASS")||as.integer(old$canonical_records)!=n||as.integer(old$final_included_records)!=included||as.integer(old$final_excluded_records)!=excluded) stop("Post-adjudication manifest does not match assembled W08 state",call.=FALSE)

manifest <- old
manifest$schema <- "living-evidence-map-workflow08-final-v3"
manifest$source_canonical_population <- n
manifest$canonical_records <- included
manifest$excluded_records <- excluded
manifest$canonical_contains_excluded_records <- FALSE
manifest$excluded_records_file <- basename(exclusions_out)
manifest$final_canonical_jsonl_sha256 <- digest(file=canonical_out,algo="sha256",serialize=FALSE)
manifest$final_canonical_jsonl_bytes <- unname(file.info(canonical_out)$size)
manifest$excluded_records_csv_sha256 <- digest(file=exclusions_out,algo="sha256",serialize=FALSE)
manifest$excluded_records_csv_bytes <- unname(file.info(exclusions_out)$size)
manifest$supersedes_output_sha256 <- old$final_canonical_jsonl_sha256
manifest$generated_at_utc <- format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ")

writeLines(toJSON(manifest,auto_unbox=TRUE,pretty=TRUE,null="null",na="null"),manifest_out,useBytes=TRUE)
cat(sprintf("PASS: W08 output partition: %d included canonical records + %d excluded bibliographic rows; canonical SHA256=%s\n",included,excluded,manifest$final_canonical_jsonl_sha256))
