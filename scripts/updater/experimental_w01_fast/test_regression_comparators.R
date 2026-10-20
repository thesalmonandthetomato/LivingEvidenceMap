#!/usr/bin/env Rscript
# Isolated regression smoke tests: parity comparators must detect real errors.
# All fixtures and reports live under tempdir(); no production data or writes.
suppressPackageStartupMessages({library(data.table);library(jsonlite)})
root <- tempfile("w01-fast-regression-")
dir.create(root)
on.exit(unlink(root, recursive=TRUE), add=TRUE)
script_dir <- "scripts/updater/experimental_w01_fast"
run_compare <- function(script, args, expect_success) {
  output <- suppressWarnings(system2(file.path(R.home("bin"),"Rscript"),
    c(file.path(script_dir,script),args),stdout=TRUE,stderr=TRUE))
  status <- attr(output,"status")
  if(is.null(status)) status <- 0L
  if(identical(as.integer(status)==0L,expect_success)) return(invisible(TRUE))
  stop(sprintf("%s returned %d; expected success=%s; output: %s",
    script,status,expect_success,paste(output,collapse=" | ")),call.=FALSE)
}
candidate_a <- data.table(record_i=c(1L,2L),record_j=c(3L,3L),blocks=c("doi;title","abstract"))
candidate_b <- copy(candidate_a)
write_case <- function(x,name) {p<-file.path(root,name);fwrite(x,p);p}
pa <- write_case(candidate_a,"candidate_reference.csv")
pb <- write_case(candidate_b,"candidate_fast.csv")
check_candidates <- function(ok) run_compare("compare_production_candidates.R",
  c("--production",pa,"--experimental",pb,"--report",file.path(root,"candidate_report.json")),ok)
check_candidates(TRUE)
candidate_b[1L,blocks:="title"]
fwrite(candidate_b,pb)
check_candidates(FALSE) # altered evidence
candidate_b <- candidate_a[-2L]
fwrite(candidate_b,pb)
check_candidates(FALSE) # missing pair
candidate_b <- rbind(candidate_a,data.table(record_i=1L,record_j=2L,blocks="title"))
fwrite(candidate_b,pb)
check_candidates(FALSE) # extra pair
cluster_a <- data.table(idx=1:3,source=c("a","b","c"),
  source_record_id=c("A","B","C"),cluster_id=c("work-1","work-1","work-2"),
  cluster_size=c(2L,2L,1L))
cluster_b <- copy(cluster_a)
ma<-write_case(cluster_a,"map_reference.csv")
mb<-write_case(cluster_b,"map_fast.csv")
check_clusters <- function(ok) run_compare("compare_cluster_maps.R",
  c("--production-map",ma,"--fast-map",mb,"--report",file.path(root,"cluster_report.json")),ok)
check_clusters(TRUE)
cluster_b[3L,cluster_id:="work-3"]
fwrite(cluster_b,mb)
check_clusters(FALSE) # changed stable ID, identical cluster count and membership
cluster_b <- copy(cluster_a)
cluster_b[,cluster_id:=c("work-1","work-2","work-2")]
cluster_b[,cluster_size:=c(1L,2L,2L)]
fwrite(cluster_b,mb)
check_clusters(FALSE) # changed membership with equal total cluster count
cat("PASS: candidate evidence, missing/extra pairs and cluster discrepancies detected\n")
