#!/usr/bin/env Rscript
# Offline, read-only guardrails. Never invoke production workflows.
suppressPackageStartupMessages(library(yaml))
expected_ref <- "8febc7b99ce1f7752c7553ed6023976a643f8621"
state <- readLines("scripts/updater/experimental_w01_fast/DEVELOPMENT_STATE.md",warn=FALSE)
stopifnot(any(grepl(expected_ref,state,fixed=TRUE)))
stopifnot(any(grepl("w01-fast-development",state,fixed=TRUE)))
for(p in c("docs/search_record/zenodo/run-39298022062.json",
           "docs/deduplication/zenodo/run-39140209398.json",
           "scripts/updater/workflow_01_deduplication_incremental_candidates.R",
           "scripts/updater/workflow_01_deduplication_merge_clusters.R",
           "scripts/updater/workflow_01_build_canonical_jsonl.R",
           "scripts/updater/workflow_01_build_delta.R",
           "scripts/updater/workflow_01_replay_delta.R"))stopifnot(file.exists(p))
w<-yaml::read_yaml(".github/workflows/workflow_01_production.yml")
stopifnot(all(c("prepare","adjudicate","canonicalise","publish")%in%names(w$jobs)))
cat("PASS: immutable reference inputs, production scripts, milestones, and development guardrails exist\n")
