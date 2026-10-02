#!/usr/bin/env Rscript
suppressPackageStartupMessages(library(data.table))

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
x <- x[same_cluster==FALSE & n_independent_families==1L]
if (nrow(x)!=1219L) stop(sprintf("Expected 1219 single-family disagreement pairs, got %d",nrow(x)),call.=FALSE)

sim <- function(a,b) {
  if (is.na(a)||is.na(b)||!nzchar(a)||!nzchar(b)) return(NA_real_)
  1 - adist(a,b)[1L] / max(nchar(a),nchar(b),1L)
}
x[, title_similarity:=mapply(sim,title_i,title_j)]
x[, year_compatible:=is.na(year_diff) | year_diff<=1]
x[, severe_year_conflict:=!is.na(year_diff) & year_diff>=3]
x[, family:=families]

# Conservative, family-aware triage. These are NOT merge decisions.
x[, triage_class:=fcase(
  family=="pmid" & year_compatible & !is.na(title_similarity) & title_similarity>=0.65,
    "strong_same_work_candidate",
  family=="mag" & year_compatible & !is.na(title_similarity) & title_similarity>=0.65,
    "strong_same_work_candidate",
  family=="doi" & year_compatible & !is.na(title_similarity) & title_similarity>=0.90,
    "strong_same_work_candidate",
  severe_year_conflict,
    "metadata_conflict_review",
  !is.na(title_similarity) & title_similarity<0.35,
    "container_or_identifier_risk",
  default="external_validation_needed"
)]

x[, source_i:=sub("::.*$","",`i.manifestation_key`)]
x[, source_j:=sub("::.*$","",manifestation_key)]
x[, pair_id:=sprintf("S%04d",.I)]

setcolorder(x,c("pair_id","family","triage_class","source_i","source_j",
                "i.manifestation_key","manifestation_key",
                "cluster_i","cluster_j","title_i","title_j",
                "title_similarity","year_i","year_j","year_diff",
                "year_compatible","severe_year_conflict","involves_appended"))

fwrite(x,file.path(output_dir,"single_family_disagreement_triage.csv"))
for (cl in unique(x$triage_class)) {
  fwrite(x[triage_class==cl],file.path(output_dir,paste0(cl,".csv")))
}
summary <- x[,.(pairs=.N,
               components=uniqueN(paste(pmin(cluster_i,cluster_j),pmax(cluster_i,cluster_j),sep="::")),
               appended_pairs=sum(involves_appended),
               median_title_similarity=median(title_similarity,na.rm=TRUE)),
             by=.(family,triage_class)][order(family,triage_class)]
fwrite(summary,file.path(output_dir,"single_family_triage_summary.csv"))
cat("PASS: single-family disagreement triage\n")
print(summary)
cat(sprintf("TOTAL=%d; zero merges or W01 modifications\n",nrow(x)))
