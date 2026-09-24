#!/usr/bin/env Rscript

suppressPackageStartupMessages(library(jsonlite))
args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag,default=NULL) {
  i <- match(flag,args)
  if (is.na(i)) return(default)
  if (i==length(args)) stop(sprintf("Missing value after %s",flag),call.=FALSE)
  args[[i+1L]]
}
receipt_path <- arg("--receipt")
registry_path <- arg("--registry")
pointer_dir <- arg("--pointer-dir")
if (any(vapply(list(receipt_path,registry_path,pointer_dir),is.null,logical(1)))) stop("Required arguments missing",call.=FALSE)
x <- fromJSON(receipt_path,simplifyVector=FALSE)
if (!identical(x$status,"published")) stop("Adjudication receipt is not published",call.=FALSE)
dir.create(dirname(registry_path),recursive=TRUE,showWarnings=FALSE)
dir.create(pointer_dir,recursive=TRUE,showWarnings=FALSE)

row <- data.frame(
  source_workflow01_run_id=as.character(x$source_workflow01_run_id),
  adjudication_github_run_id=as.character(x$adjudication_github_run_id),
  state=as.character(x$state),
  model=as.character(x$model),
  auto_threshold=as.numeric(x$auto_threshold),
  total_cases=as.integer(x$total_cases),
  automatic_duplicate=as.integer(x$automatic_duplicate),
  automatic_not_duplicate=as.integer(x$automatic_not_duplicate),
  human_review_required=as.integer(x$human_review_required),
  technical_failures=as.integer(x$technical_failures),
  zenodo_record_id=as.character(x$zenodo_record_id),
  doi=as.character(x$doi),
  record_url=as.character(x$record_url),
  manifest_sha256=as.character(x$manifest_sha256),
  published_at_utc=as.character(x$published_at_utc),
  stringsAsFactors=FALSE
)
if(file.exists(registry_path)) {
  old <- read.csv(registry_path,stringsAsFactors=FALSE,check.names=FALSE)
  old <- old[as.character(old$adjudication_github_run_id)!=row$adjudication_github_run_id,,drop=FALSE]
  out <- rbind(old,row)
} else out <- row
write.csv(out,registry_path,row.names=FALSE,na="")

pointer <- file.path(pointer_dir,paste0("run-",row$source_workflow01_run_id,".json"))
if(!file.copy(receipt_path,pointer,overwrite=TRUE)) stop("Failed to write adjudication Zenodo pointer",call.=FALSE)
cat(sprintf("PASS: registered Workflow 01 adjudication record %s for source run %s\n",
            row$zenodo_record_id,row$source_workflow01_run_id))
