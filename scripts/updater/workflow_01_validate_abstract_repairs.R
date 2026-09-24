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
queue_path <- arg("--queue")
repairs_path <- arg("--repairs")
output_path <- arg("--output")
if(any(vapply(list(queue_path,repairs_path,output_path),is.null,logical(1)))) stop("Required: --queue --repairs --output",call.=FALSE)

read_jsonl <- function(path){
  x <- readLines(path,warn=FALSE,encoding="UTF-8")
  x <- x[nzchar(trimws(x))]
  lapply(x,fromJSON,simplifyVector=FALSE)
}
q <- read_jsonl(queue_path)
r <- read_jsonl(repairs_path)

key <- function(z) paste(as.character(z$review_case_id),as.character(z$source),as.character(z$source_record_id),sep="|")
qkeys <- vapply(q,key,character(1))
rkeys <- vapply(r,key,character(1))
if(anyDuplicated(qkeys)) stop("Repair queue contains duplicate keys",call.=FALSE)
if(anyDuplicated(rkeys)) stop("Repair decisions contain duplicate keys",call.=FALSE)
if(length(setdiff(rkeys,qkeys))) stop("Repair decisions contain records not present in repair queue",call.=FALSE)
missing <- setdiff(qkeys,rkeys)
if(length(missing)) stop(sprintf("%d abstract repair items remain unresolved",length(missing)),call.=FALSE)

allowed <- c("replace_abstract","strip_abstract_no_verified_replacement")
for(z in r){
  if(is.null(z$action)||!(z$action %in% allowed)) stop("Invalid abstract repair action",call.=FALSE)
  if(is.null(z$verified_by)||!nzchar(trimws(as.character(z$verified_by)))) stop("verified_by is required",call.=FALSE)
  if(is.null(z$verified_at_utc)||!nzchar(trimws(as.character(z$verified_at_utc)))) stop("verified_at_utc is required",call.=FALSE)
  if(identical(z$action,"replace_abstract")){
    if(is.null(z$replacement_abstract)||!nzchar(trimws(as.character(z$replacement_abstract)))) stop("Replacement abstract is required",call.=FALSE)
    if(is.null(z$replacement_source)||!nzchar(trimws(as.character(z$replacement_source)))) stop("Replacement source is required",call.=FALSE)
    if(is.null(z$replacement_match_basis)||!nzchar(trimws(as.character(z$replacement_match_basis)))) stop("Replacement match basis is required",call.=FALSE)
    if(grepl("^copied_from_pair$",as.character(z$replacement_match_basis),ignore.case=TRUE)) stop("Copying an abstract from the paired record is not permitted as a verification basis",call.=FALSE)
  }
}

dir.create(dirname(output_path),recursive=TRUE,showWarnings=FALSE)
manifest <- list(
  schema="living-evidence-map-workflow01-abstract-repair-validation-v1",
  queue_sha256=digest(file=queue_path,algo="sha256",serialize=FALSE),
  repairs_sha256=digest(file=repairs_path,algo="sha256",serialize=FALSE),
  queue_items=length(q),
  resolved_items=length(r),
  replacement_abstracts=sum(vapply(r,function(z)identical(z$action,"replace_abstract"),logical(1))),
  stripped_without_replacement=sum(vapply(r,function(z)identical(z$action,"strip_abstract_no_verified_replacement"),logical(1))),
  complete=TRUE,
  deduplication_may_resume=TRUE
)
writeLines(toJSON(manifest,auto_unbox=TRUE,pretty=TRUE,null="null"),output_path,useBytes=TRUE)
cat(sprintf("PASS: validated %d/%d abstract repairs; deduplication may resume\n",length(r),length(q)))
