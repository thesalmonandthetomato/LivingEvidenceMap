#!/usr/bin/env Rscript
# W01 explicit historical false-merge corrections survive streaming finalisation.
suppressPackageStartupMessages({library(data.table);library(jsonlite);library(digest)})
td <- tempfile("w01-split-stream-");stopifnot(dir.create(td))
meta <- data.table(idx=1:3,source="lens",source_record_id=as.character(1:3))
fwrite(meta,file.path(td,"meta.csv"))
pairs <- data.table(record_i=c(1L,1L,2L),record_j=c(2L,3L,3L),
  pair_key=c("1::2","1::3","2::3"),
  rescored_classification=c("duplicate","not_duplicate","not_duplicate"),
  rescored_rule=c("previous_duplicate","different","different"),
  review_route="none",
  notes=c("old false merge","distinct","distinct"))
fwrite(pairs,file.path(td,"combined.csv"))
prev <- data.table(idx=1:3,source="lens",source_record_id=as.character(1:3),
  cluster_id=c("work-old-split","work-old-split","work-other"))
fwrite(prev,file.path(td,"previous.csv"))
file.create(file.path(td,"llm.jsonl"),file.path(td,"human.jsonl"))
writeLines(toJSON(list(resume_allowed=TRUE,active_decisions=0L),auto_unbox=TRUE),
  file.path(td,"integrity.json"))
cfg <- list(schema="living-evidence-map-workflow01-explicit-cluster-splits-v1",
  corrections=list(list(previous_cluster_id="work-old-split",reason="fixture false merge",
    preserve_group="first",
    groups=list(
      list(group="first",members=list(list(source="lens",source_record_id="1"))),
      list(group="second",members=list(list(source="lens",source_record_id="2")))
    ))))
writeLines(toJSON(cfg,auto_unbox=TRUE,pretty=TRUE),
  file.path(td,"splits.json"))
out <- file.path(td,"out")
args <- c("scripts/updater/workflow_01_apply_adjudications_and_recluster.R",
  "--combined-decisions",file.path(td,"combined.csv"),
  "--manifestation-map",file.path(td,"meta.csv"),
  "--llm-adjudications",file.path(td,"llm.jsonl"),
  "--human-decisions",file.path(td,"human.jsonl"),
  "--human-integrity-manifest",file.path(td,"integrity.json"),
  "--previous-cluster-map",file.path(td,"previous.csv"),
  "--explicit-cluster-splits",file.path(td,"splits.json"),
  "--output-dir",out)
z <- suppressWarnings(system2("Rscript",args,stdout=TRUE,stderr=TRUE))
cat(paste(z,collapse="\n"),"\n")
st <- attr(z,"status");if(is.null(st))st<-0L
stopifnot(st==0L)
f <- fread(file.path(out,"final_pair_decisions.csv"))
stopifnot(identical(f[pair_key=="1::2",rescored_classification],"not_duplicate"),
  identical(f[pair_key=="1::2",rescored_rule],"workflow01_explicit_cluster_split"))
m <- fread(file.path(out,"manifestation_cluster_map.csv"))
stopifnot(identical(m[idx==1L,cluster_id],"work-old-split"),
  !identical(m[idx==2L,cluster_id],"work-old-split"),uniqueN(m$cluster_id)==3L)
summary <- fromJSON(file.path(out,"summary.json"))
stopifnot(summary$explicit_cluster_split_corrections==1L,
  summary$automatic_duplicate_edges==0L,summary$unresolved_pair_decisions==0L)
audit <- fromJSON(readLines(file.path(out,"explicit_cluster_split_audit.jsonl"))[[1L]])
stopifnot(audit$cross_group_pair_rows_overridden==1L)
cat("ALL_W01_EXPLICIT_SPLIT_STREAMING_TESTS_PASS\n")
unlink(td,recursive=TRUE)
