#!/usr/bin/env Rscript
suppressPackageStartupMessages({library(jsonlite);library(digest)})
source("R/storage_local.R")
source("R/w01_contract.R")

args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag, default=NULL) {
  i <- match(flag,args)
  if (is.na(i)) return(default)
  if (i==length(args)) stop("Missing value after ",flag,call.=FALSE)
  args[[i+1L]]
}
input <- arg("--input","local_state/w01_decisions.jsonl")
output <- arg("--output","local_state/human_decisions.export.jsonl")
export_w01_decisions(input,output)
cat(sprintf("PASS: exported W01 decisions to %s\n",output))
