#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(jsonlite)
  library(digest)
})

args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag,default=NULL) {
  i <- match(flag,args)
  if (is.na(i)) return(default)
  if (i==length(args)) stop(sprintf("Missing value after %s",flag),call.=FALSE)
  args[[i+1L]]
}
input_path <- arg("--input")
exclude_path <- arg("--exclude")
output_dir <- arg("--output-dir")
seed <- arg("--seed","workflow01-targeted-exact-abstract-audit-v1-2026-09-24")
n <- as.integer(arg("--n","20"))
if(any(vapply(list(input_path,exclude_path,output_dir),is.null,logical(1)))) stop("Required: --input --exclude --output-dir",call.=FALSE)

read_jsonl <- function(path) {
  x <- readLines(path,warn=FALSE,encoding="UTF-8")
  x <- x[nzchar(trimws(x))]
  lapply(x,fromJSON,simplifyVector=FALSE)
}
write_jsonl <- function(x,path) {
  con <- file(path,"wt",encoding="UTF-8")
  on.exit(close(con),add=TRUE)
  for(z in x) writeLines(toJSON(z,auto_unbox=TRUE,null="null",na="null"),con,useBytes=TRUE)
}
strip_model <- function(z) {
  drop <- c("requested_model","resolved_model","response_id","api_usage",
            "model_decision","model_confidence","model_rationale",
            "auto_threshold","promotion","promotion_reason",
            "technical_error","adjudicated_at_utc")
  z[setdiff(names(z),drop)]
}

rows <- read_jsonl(input_path)
excluded <- read_jsonl(exclude_path)
exclude_ids <- vapply(excluded,function(z)as.character(z$review_case_id),character(1))

stratum <- Filter(function(z) {
  identical(z$promotion,"duplicate") &&
    !is.null(z$deterministic_evidence$classifier_rule) &&
    identical(z$deterministic_evidence$classifier_rule,"exact_abstract_insufficient_metadata")
},rows)

eligible <- Filter(function(z) !(as.character(z$review_case_id) %in% exclude_ids),stratum)
if(length(eligible)<n) stop("Not enough eligible targeted-audit cases",call.=FALSE)
hashes <- vapply(eligible,function(z)digest(paste(seed,z$review_case_id,sep="|"),algo="sha256",serialize=FALSE),character(1))
ord <- order(hashes,vapply(eligible,function(z)as.character(z$review_case_id),character(1)))
selected <- eligible[ord[seq_len(n)]]

dir.create(output_dir,recursive=TRUE,showWarnings=FALSE)
out_path <- file.path(output_dir,"targeted_exact_abstract_audit_20_blinded.jsonl")
write_jsonl(lapply(selected,strip_model),out_path)

manifest <- list(
  schema="living-evidence-map-workflow01-targeted-exact-abstract-audit-v1",
  seed=seed,
  population_rule="promotion=duplicate AND deterministic_evidence.classifier_rule=exact_abstract_insufficient_metadata",
  full_population=length(stratum),
  excluded_original_validation_ids=sum(vapply(stratum,function(z)as.character(z$review_case_id) %in% exclude_ids,logical(1))),
  eligible_population=length(eligible),
  targeted_sample_size=length(selected),
  selection="deterministic SHA-256 ordering after excluding cases already in original validation sample",
  selected_review_case_ids=vapply(selected,function(z)as.character(z$review_case_id),character(1)),
  source_sha256=digest(file=input_path,algo="sha256",serialize=FALSE),
  exclusion_sha256=digest(file=exclude_path,algo="sha256",serialize=FALSE),
  blinded_sample_sha256=digest(file=out_path,algo="sha256",serialize=FALSE)
)
writeLines(toJSON(manifest,auto_unbox=TRUE,pretty=TRUE,null="null"),file.path(output_dir,"targeted_exact_abstract_audit_manifest.json"),useBytes=TRUE)
cat(sprintf("PASS: targeted audit built: population=%d eligible=%d sample=%d\n",length(stratum),length(eligible),length(selected)))
