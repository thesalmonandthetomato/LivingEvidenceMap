#!/usr/bin/env Rscript
# Read-only experimental combination of exact-block and fuzzy-title W01 candidates.
suppressPackageStartupMessages({library(data.table);library(jsonlite);library(digest)})
args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag) {i<-match(flag,args);if(is.na(i)||i==length(args))stop(paste("Missing",flag));args[[i+1L]]}
exact_path<-arg("--exact"); fuzzy_path<-arg("--fuzzy");output<-arg("--output")
exact<-fread(exact_path); fuzzy<-fread(fuzzy_path)
stopifnot(all(c("record_i","record_j","blocks") %in% names(exact)),
          all(c("record_i","record_j","shared_rare_qgrams") %in% names(fuzzy)))
a<-exact[,.(record_i,record_j,block=blocks)]
a<-a[,.(block=unlist(strsplit(block,";",fixed=TRUE))),by=.(record_i,record_j)]
b<-fuzzy[,.(record_i,record_j,block="rare_qgram_title")]
combined<-rbindlist(list(a,b),use.names=TRUE)
if(nrow(combined)){
  stopifnot(all(combined$record_i<combined$record_j))
  combined<-combined[,.(blocks=paste(sort(unique(block)),collapse=";")),by=.(record_i,record_j)]
  setorder(combined,record_i,record_j)
}else combined<-data.table(record_i=integer(),record_j=integer(),blocks=character())
dir.create(dirname(output),recursive=TRUE,showWarnings=FALSE)
fwrite(combined,output)
writeLines(toJSON(list(schema="experimental-w01-fast-combined-candidates-v1",
  exact_pairs=nrow(exact),fuzzy_pairs=nrow(fuzzy),union_pairs=nrow(combined),
  exact_sha256=digest(file=exact_path,algo="sha256",serialize=FALSE),
  fuzzy_sha256=digest(file=fuzzy_path,algo="sha256",serialize=FALSE),
  production_publication_allowed=FALSE),auto_unbox=TRUE,pretty=TRUE),
  paste0(output,".manifest.json"))
cat(sprintf("EXPERIMENTAL: %d distinct incremental candidates; no production writes\n",nrow(combined)))
