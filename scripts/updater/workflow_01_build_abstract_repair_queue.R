#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(jsonlite)
  library(digest)
})

args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag,default=NULL){
  i <- match(flag,args)
  if(is.na(i)) return(default)
  if(i==length(args)) stop(sprintf("Missing value after %s",flag),call.=FALSE)
  args[[i+1L]]
}
input_path <- arg("--input")
output_path <- arg("--output")
if(is.null(input_path)||is.null(output_path)) stop("Required: --input --output",call.=FALSE)

read_jsonl <- function(path){
  x <- readLines(path,warn=FALSE,encoding="UTF-8")
  x <- x[nzchar(trimws(x))]
  lapply(x,fromJSON,simplifyVector=FALSE)
}
rows <- read_jsonl(input_path)
out <- list()
for(z in rows){
  if(!identical(z$promotion_reason,"abstract_title_inconsistency_guard")) next
  sides <- c(
    if(!isTRUE(z$abstract_consistent_with_record_i)) "record_i" else NULL,
    if(!isTRUE(z$abstract_consistent_with_record_j)) "record_j" else NULL
  )
  for(side in sides){
    rec <- z[[side]]
    out[[length(out)+1L]] <- list(
      schema="living-evidence-map-workflow01-abstract-repair-item-v1",
      review_case_id=as.character(z$review_case_id),
      pair_key=as.character(z$pair_key),
      suspect_side=side,
      source=as.character(rec$source),
      source_record_id=as.character(rec$source_record_id),
      title=rec$title,
      authors=rec$authors,
      year=rec$year,
      doi=rec$doi,
      current_abstract=rec$abstract,
      repair_status="pending_verified_replacement",
      allowed_actions=c("replace_abstract","strip_abstract_no_verified_replacement"),
      replacement_abstract=NULL,
      replacement_source=NULL,
      replacement_match_basis=NULL
    )
  }
}

dir.create(dirname(output_path),recursive=TRUE,showWarnings=FALSE)
con <- file(output_path,"wt",encoding="UTF-8")
on.exit(close(con),add=TRUE)
for(z in out) writeLines(toJSON(z,auto_unbox=TRUE,null="null",na="null"),con,useBytes=TRUE)
close(con); on.exit(NULL,add=FALSE)

manifest <- list(
  schema="living-evidence-map-workflow01-abstract-repair-queue-manifest-v1",
  source_adjudication_sha256=digest(file=input_path,algo="sha256",serialize=FALSE),
  repair_items=length(out),
  unique_source_records=length(unique(vapply(out,function(z)paste(z$source,z$source_record_id,sep=":"),character(1))))
)
writeLines(toJSON(manifest,auto_unbox=TRUE,pretty=TRUE,null="null"),paste0(output_path,".manifest.json"),useBytes=TRUE)
cat(sprintf("PASS: built abstract repair queue with %d items\n",length(out)))
