#!/usr/bin/env Rscript
# Read-only publication contract audit for a staged W01-Fast handoff.
# Does not run the publisher, write data, access Zenodo, or dispatch W02.
suppressPackageStartupMessages({library(jsonlite);library(digest);library(data.table)})
args<-commandArgs(trailingOnly=TRUE)
value<-function(flag){i<-match(flag,args);if(is.na(i)||i==length(args))stop("Missing ",flag);args[[i+1L]]}
root<-value("--root")
p<-function(...)file.path(root,...)
required<-c(
 "previous_state/workflow01_full_five_source/summary.json",
 "previous_state/workflow01_full_five_source/manifestation_cluster_map.csv",
 "previous_state/canonical/records.jsonl",
 "outputs/workflow01_union/source_inputs.json",
 "outputs/final/summary.json",
 "outputs/final/manifestation_cluster_map.csv",
 "outputs/final/final_pair_decisions.csv",
 "outputs/final/abstract_strip_actions.jsonl",
 "outputs/final/cumulative_data_quality_repairs.jsonl",
 "outputs/canonical/records.jsonl",
 "outputs/canonical/canonical_manifest.json",
 "outputs/canonical/data_quality_repair_application.jsonl",
 "outputs/human_gate/normalised/data_quality_repairs.normalised.jsonl",
 "outputs/workflow01_stage_canonicalise_checksums.txt",
 "outputs/delta/delta_manifest.json",
 "outputs/replayed/workflow01_delta_replay_audit.json"
)
missing<-required[!file.exists(file.path(root,required))]
if(length(missing))stop("NOT READY: missing authoritative publication inputs:\n",paste(missing,collapse="\n"))
# The canonicalise stage's checksum file must be verified, not manufactured.
checks<-readLines(p("outputs/workflow01_stage_canonicalise_checksums.txt"),warn=FALSE)
if(!length(checks)||any(!grepl("^[0-9a-f]{64}  ",checks)))
 stop("NOT READY: malformed canonicalise-stage checksums")
for(line in checks){
 hash<-substr(line,1,64);rel<-substring(line,67)
 if(startsWith(rel,"/")||grepl("(^|/)\\.\\.(/|$)",rel)||!file.exists(p(rel)))
  stop("NOT READY: unsafe or missing stage checksum target: ",rel)
 observed<-digest(file=p(rel),algo="sha256",serialize=FALSE)
 if(!identical(observed,hash))stop("NOT READY: checksum mismatch: ",rel)
}
m<-fromJSON(p("outputs/canonical/canonical_manifest.json"))
s<-fromJSON(p("outputs/final/summary.json"))
r<-fromJSON(p("outputs/replayed/workflow01_delta_replay_audit.json"))
d<-fromJSON(p("outputs/delta/delta_manifest.json"),simplifyVector=FALSE)
if(!isTRUE(as.integer(m$records)>0L)||
 !identical(as.integer(m$records),as.integer(s$clusters))||
 !identical(as.integer(m$source_manifestations),as.integer(s$source_manifestations))||
 !identical(as.integer(m$records),as.integer(r$canonical_records))||
 !identical(as.integer(m$source_manifestations),as.integer(r$source_manifestations))||
 !identical(as.integer(m$records),as.integer(d$target$canonical_records))||
 !identical(as.integer(m$source_manifestations),as.integer(d$target$source_manifestations))||
 !identical(r$status,"PASS"))stop("NOT READY: canonical, summary, delta and replay disagree")
sha<-digest(file=p("outputs/canonical/records.jsonl"),algo="sha256",serialize=FALSE)
if(!identical(sha,as.character(m$canonical_jsonl_sha256))||
 !identical(sha,as.character(r$canonical_jsonl_sha256)))
 stop("NOT READY: replayed canonical output hash mismatch")
old<-fromJSON(p("previous_state/workflow01_full_five_source/summary.json"))
if(is.null(old$source_manifestations))stop("NOT READY: prior state summary missing provenance")
invisible(fromJSON(p("outputs/workflow01_union/source_inputs.json"),simplifyVector=FALSE))
cat("PASS: required files, canonicalise checksums, previous state, and delta replay contract verified. No publication.\n")
