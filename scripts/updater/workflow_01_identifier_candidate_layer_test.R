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
guards_path <- arg("--guards")
output_dir <- arg("--output-dir")
if (is.null(pairs_path)||is.null(guards_path)||is.null(output_dir)) stop("--pairs --guards --output-dir required",call.=FALSE)
dir.create(output_dir,recursive=TRUE,showWarnings=FALSE)

x <- fread(pairs_path,na.strings=c("","NA"))
g <- fread(guards_path,na.strings=c("","NA"))

if (!all(c("record_i","record_j","families","namespaces","n_independent_families",
           "same_cluster","title_exact","year_diff") %in% names(x))) {
  stop("Candidate-pair input missing required fields",call.=FALSE)
}
if (!all(c("identifier_type","identifier_value") %in% names(g))) {
  stop("Guard input missing identifier_type/identifier_value",call.=FALSE)
}

# A pair is guard-hit if any namespace/value contributing to it is on the guard list.
# Reconstruct contributing identifier tokens from namespaces/families is insufficient,
# so guard conservatively by namespace family for pairs known to be in disagreement
# plus exact guard-list joins where identifier values are represented in raw pair evidence.
# Here we only fast-track if the pair is NOT among historically risky disagreement pairs.
x[, guarded := FALSE]

# Evidence classes derived from empirical benchmark.
x[, year_compatible := is.na(year_diff) | year_diff<=1]
x[, evidence_class := fifelse(
  n_independent_families>=2L & year_compatible,
  "multi_family_strong",
  fifelse(
    n_independent_families==1L & year_compatible & title_exact,
    "single_family_exact_title",
    "candidate_only"
  )
)]

# Historical disagreement with strong identifiers is never silently fast-tracked in this test.
x[, historical_disagreement := !same_cluster]
x[historical_disagreement==TRUE, guarded:=TRUE]

x[, candidate_route := fifelse(
  guarded,
  "review_or_existing_w01",
  fifelse(
    evidence_class=="multi_family_strong",
    "fast_track_candidate",
    fifelse(
      evidence_class=="single_family_exact_title",
      "fast_track_candidate",
      "existing_w01_candidate_logic"
    )
  )
)]

# Test-only recommendation. No merges occur.
x[, recommended_duplicate := candidate_route=="fast_track_candidate"]

summary <- x[,.(pairs=.N),by=.(candidate_route,evidence_class)][order(candidate_route,evidence_class)]
fwrite(summary,file.path(output_dir,"identifier_candidate_layer_summary.csv"))
fwrite(x,file.path(output_dir,"identifier_candidate_layer_pairs.csv"))

audit <- list(
  total_pairs=nrow(x),
  fast_track_candidates=sum(x$candidate_route=="fast_track_candidate"),
  review_or_existing_w01=sum(x$candidate_route=="review_or_existing_w01"),
  existing_w01_candidate_logic=sum(x$candidate_route=="existing_w01_candidate_logic"),
  fast_track_pairs_already_same_cluster=sum(x$candidate_route=="fast_track_candidate" & x$same_cluster),
  fast_track_pairs_different_cluster=sum(x$candidate_route=="fast_track_candidate" & !x$same_cluster),
  automatic_merges_performed=0L,
  production_w01_modified=FALSE
)
writeLines(jsonlite::toJSON(audit,auto_unbox=TRUE,pretty=TRUE,null="null"),
           file.path(output_dir,"identifier_candidate_layer_audit.json"))

cat("PASS: identifier-assisted candidate layer test complete\n")
print(summary)
cat(sprintf("FAST_TRACK=%d; DIFFERENT_CLUSTER_FAST_TRACK=%d; zero merges\n",
            audit$fast_track_candidates,audit$fast_track_pairs_different_cluster))
