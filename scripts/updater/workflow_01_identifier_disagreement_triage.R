#!/usr/bin/env Rscript
suppressPackageStartupMessages({
  library(data.table)
})

args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag,default=NULL) {
  i <- match(flag,args)
  if (is.na(i)) return(default)
  if (i==length(args)) stop(sprintf("Missing value after %s",flag),call.=FALSE)
  args[[i+1L]]
}
pairs_path <- arg("--pairs")
output_dir <- arg("--output-dir")
if (is.null(pairs_path)||is.null(output_dir)) stop("--pairs and --output-dir are required",call.=FALSE)
dir.create(output_dir,recursive=TRUE,showWarnings=FALSE)

x <- fread(pairs_path,na.strings=c("","NA"))
x <- x[same_cluster==FALSE & n_independent_families>=2L]
if (!nrow(x)) stop("No high-evidence disagreement pairs found",call.=FALSE)

seq_ratio <- function(a,b) {
  if (is.na(a)||is.na(b)||!nzchar(a)||!nzchar(b)) return(NA_real_)
  aa <- strsplit(a,"",fixed=TRUE)[[1L]]
  bb <- strsplit(b,"",fixed=TRUE)[[1L]]
  # LCS-based Dice-like sequence similarity via adist is too costly here.
  # Use normalised Levenshtein similarity on already-normalised titles.
  d <- adist(a,b,ignore.case=FALSE)[1L]
  1 - d / max(nchar(a),nchar(b),1L)
}
x[, title_similarity:=mapply(seq_ratio,title_i,title_j)]
x[, year_compatible:=is.na(year_diff) | year_diff<=1]
x[, severe_year_conflict:=!is.na(year_diff) & year_diff>=3]

# Conservative triage only. These labels are NOT merge decisions.
# likely_w01_miss: multiple independent ID families + compatible year + strong title agreement.
# metadata_or_identifier_conflict: strong bibliographic contradiction despite multiple IDs.
# ambiguous_manual: everything between those bounds.
x[, triage_class:=fifelse(
  year_compatible & !is.na(title_similarity) & title_similarity>=0.65,
  "likely_w01_miss",
  fifelse(
    severe_year_conflict | (!is.na(title_similarity) & title_similarity<0.35),
    "metadata_or_identifier_conflict",
    "ambiguous_manual"
  )
)]

x[, source_i:=sub("::.*$","",`i.manifestation_key`)]
x[, source_j:=sub("::.*$","",manifestation_key)]
x[, pair_id:=sprintf("H%04d",.I)]

setcolorder(x,c("pair_id","triage_class","families","namespaces",
                "n_independent_families","source_i","source_j",
                "i.manifestation_key","manifestation_key",
                "cluster_i","cluster_j","title_i","title_j",
                "title_similarity","year_i","year_j","year_diff",
                "year_compatible","severe_year_conflict","involves_appended"))

fwrite(x,file.path(output_dir,"high_evidence_disagreement_triage.csv"))
for (cl in c("likely_w01_miss","metadata_or_identifier_conflict","ambiguous_manual")) {
  fwrite(x[triage_class==cl],file.path(output_dir,paste0(cl,".csv")))
}

summary <- x[,.(pairs=.N,
               components=uniqueN(paste(pmin(cluster_i,cluster_j),pmax(cluster_i,cluster_j),sep="::")),
               appended_pairs=sum(involves_appended),
               median_title_similarity=median(title_similarity,na.rm=TRUE)),
             by=triage_class][order(triage_class)]
fwrite(summary,file.path(output_dir,"triage_summary.csv"))

cat("PASS: high-evidence disagreement triage\n")
print(summary)
cat(sprintf("TOTAL=%d; no merges or W01 modifications performed\n",nrow(x)))
