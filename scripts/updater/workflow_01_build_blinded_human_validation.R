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
output_dir <- arg("--output-dir")
seed <- arg("--seed","workflow01-validation-v1-2026-09-24")
n_per_class <- as.integer(arg("--n-per-class","20"))
if (is.null(input_path)||is.null(output_dir)) stop("Required: --input --output-dir",call.=FALSE)
dir.create(output_dir,recursive=TRUE,showWarnings=FALSE)

lines <- readLines(input_path,warn=FALSE,encoding="UTF-8")
lines <- lines[nzchar(trimws(lines))]
rows <- lapply(lines,fromJSON,simplifyVector=FALSE)

strip_model <- function(z) {
  drop <- c("requested_model","resolved_model","response_id","api_usage",
            "model_decision","model_confidence","model_rationale",
            "auto_threshold","promotion","promotion_reason",
            "technical_error","adjudicated_at_utc")
  z[setdiff(names(z),drop)]
}
write_jsonl <- function(x,path) {
  con <- file(path,"wt",encoding="UTF-8")
  on.exit(close(con),add=TRUE)
  for(z in x) writeLines(toJSON(z,auto_unbox=TRUE,null="null",na="null"),con,useBytes=TRUE)
}

human <- Filter(function(z) identical(z$promotion,"human_review"),rows)
write_jsonl(lapply(human,strip_model),file.path(output_dir,"human_review_132_blinded.jsonl"))

sample_stratum <- function(label) {
  x <- Filter(function(z) identical(z$promotion,label),rows)
  if (length(x)<n_per_class) stop(sprintf("Not enough %s cases",label),call.=FALSE)
  hashes <- vapply(x,function(z)digest(paste(seed,z$review_case_id,sep="|"),
                                      algo="sha256",serialize=FALSE),character(1))
  x[order(hashes,vapply(x,function(z)z$review_case_id,character(1)))[seq_len(n_per_class)]]
}
d <- sample_stratum("duplicate")
n <- sample_stratum("not_duplicate")
selected <- c(d,n)

# Interleave deterministically without exposing class labels.
mix_hash <- vapply(selected,function(z)digest(paste("mix",seed,z$review_case_id,sep="|"),
                                            algo="sha256",serialize=FALSE),character(1))
selected <- selected[order(mix_hash)]
write_jsonl(lapply(selected,strip_model),file.path(output_dir,"validation_sample_40_blinded.jsonl"))

manifest <- list(
  schema="living-evidence-map-workflow01-human-validation-sample-v1",
  source_cases=length(rows),
  unresolved_human_review_cases=length(human),
  validation_sample_size=length(selected),
  sample_design="stratified deterministic hash sample: 20 automatic duplicate + 20 automatic not_duplicate; labels withheld from reviewer",
  seed=seed,
  n_per_class=n_per_class,
  selected_review_case_ids=vapply(selected,function(z)z$review_case_id,character(1)),
  source_sha256=digest(file=input_path,algo="sha256",serialize=FALSE),
  blinded_human_review_sha256=digest(file=file.path(output_dir,"human_review_132_blinded.jsonl"),algo="sha256",serialize=FALSE),
  blinded_validation_sha256=digest(file=file.path(output_dir,"validation_sample_40_blinded.jsonl"),algo="sha256",serialize=FALSE)
)
writeLines(toJSON(manifest,auto_unbox=TRUE,pretty=TRUE,null="null"),
           file.path(output_dir,"validation_sample_manifest.json"))
cat(sprintf("PASS: built blinded review set: %d unresolved cases + %d validation cases\n",
            length(human),length(selected)))
