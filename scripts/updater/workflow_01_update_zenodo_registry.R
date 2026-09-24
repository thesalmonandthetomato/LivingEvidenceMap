#!/usr/bin/env Rscript

suppressPackageStartupMessages(library(jsonlite))
args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag,default=NULL) {
  i <- match(flag,args)
  if (is.na(i)) return(default)
  if (i == length(args)) stop(sprintf("Missing value after %s",flag),call.=FALSE)
  args[[i+1L]]
}

receipt_path <- arg("--receipt")
registry_path <- arg("--registry")
pointer_dir <- arg("--pointer-dir")
if (any(vapply(list(receipt_path,registry_path,pointer_dir),is.null,logical(1)))) {
  stop("Required: --receipt --registry --pointer-dir",call.=FALSE)
}
x <- fromJSON(receipt_path,simplifyVector=FALSE)
if (!identical(x$status,"published")) stop("Receipt is not published",call.=FALSE)
dir.create(dirname(registry_path),recursive=TRUE,showWarnings=FALSE)
dir.create(pointer_dir,recursive=TRUE,showWarnings=FALSE)

row <- data.frame(
  github_run_id=as.character(x$github_run_id),
  state=as.character(x$state),
  source_manifestations=as.integer(x$source_manifestations),
  preserved_pair_decisions=as.integer(x$preserved_pair_decisions),
  incremental_pair_decisions=as.integer(x$incremental_pair_decisions),
  manual_review_pairs=as.integer(x$manual_review_pairs),
  canonical_records=if(is.null(x$canonical_records)) NA_integer_ else as.integer(x$canonical_records),
  canonical_jsonl_sha256=if(is.null(x$canonical_jsonl_sha256)) NA_character_ else as.character(x$canonical_jsonl_sha256),
  canonical_jsonl_bytes=if(is.null(x$canonical_jsonl_bytes)) NA_real_ else as.numeric(x$canonical_jsonl_bytes),
  zenodo_record_id=as.character(x$zenodo_record_id),
  doi=as.character(x$doi),
  record_url=as.character(x$record_url),
  visibility=as.character(x$visibility),
  manifest_sha256=as.character(x$manifest_sha256),
  published_at_utc=as.character(x$published_at_utc),
  stringsAsFactors=FALSE
)
if (file.exists(registry_path)) {
  old <- read.csv(registry_path,stringsAsFactors=FALSE,check.names=FALSE)
  old <- old[as.character(old$github_run_id) != row$github_run_id,,drop=FALSE]
  out <- rbind(old,row)
} else out <- row
out <- out[order(suppressWarnings(as.numeric(out$github_run_id))),,drop=FALSE]
write.csv(out,registry_path,row.names=FALSE,na="")

pointer <- file.path(pointer_dir,paste0("run-",row$github_run_id,".json"))
if (!file.copy(receipt_path,pointer,overwrite=TRUE)) stop("Failed to write Workflow 01 Zenodo pointer",call.=FALSE)
cat(sprintf("PASS: registered Workflow 01 Zenodo record %s for run %s\n",
            row$zenodo_record_id,row$github_run_id))
