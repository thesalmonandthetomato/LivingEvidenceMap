#!/usr/bin/env Rscript
# Isolated, fail-closed W01-Fast -> existing W01 final/canonical/delta handoff.
# Copies verified outputs only. NO publication, no repository writes, no W02 dispatch.
suppressPackageStartupMessages({library(jsonlite);library(digest);library(data.table)})
args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag) { i<-match(flag,args); if(is.na(i)||i==length(args)) stop("Missing ",flag); args[[i+1L]] }
root <- arg("--fast-root"); out <- arg("--output-root")
if(dir.exists(out)||file.exists(out)) stop("Refusing to overwrite handoff output")
p <- function(...) file.path(root,...)
src <- list(
 final_map=p("production_final","manifestation_cluster_map.csv"),
 final_pairs=p("production_final","final_pair_decisions.csv"),
 final_summary=p("production_final","summary.json"),
 final_aliases=p("production_final","cluster_id_aliases.csv"),
 final_strips=p("production_final","abstract_strip_actions.jsonl"),
 final_repairs=p("production_final","cumulative_data_quality_repairs.jsonl"),
 canonical=p("replayed","canonical","records.jsonl"),
 canonical_manifest=p("production_canonical","canonical_manifest.json"),
 repair_audit=p("production_canonical","data_quality_repair_application.jsonl"),
 delta_manifest=p("delta","delta_manifest.json"),
 replay_audit=p("replayed","workflow01_delta_replay_audit.json")
)
if(any(!file.exists(unlist(src))) || any(file.info(unlist(src))$isdir)) stop("Missing authoritative Fast outputs")
run <- fromJSON(p("run_report.json"))
if(!identical(run$status,"PASS_SHADOW_NO_PUBLICATION")) stop("Fast run not validated")
rep <- fromJSON(src$replay_audit)
if(!identical(rep$status,"PASS")) stop("Delta replay did not pass")
summ <- fromJSON(src$final_summary)
cm <- fromJSON(src$canonical_manifest)
delta <- fromJSON(src$delta_manifest,simplifyVector=FALSE)
n <- as.integer(summ$source_manifestations)
k <- as.integer(summ$clusters)
if(is.na(n)||is.na(k)||n<1L||k<1L||
 !identical(as.integer(cm$records),k)||
 !identical(as.integer(cm$source_manifestations),n)||
 !identical(as.integer(rep$source_manifestations),n)||
 !identical(as.integer(rep$canonical_records),k)||
 !identical(as.integer(delta$target$source_manifestations),n)||
 !identical(as.integer(delta$target$canonical_records),k))stop("Fast summary, replay and delta counts disagree")
sha <- function(file) digest(file=file,algo="sha256",serialize=FALSE)
if(!identical(sha(src$canonical),as.character(rep$canonical_jsonl_sha256))||
 !identical(sha(src$canonical),as.character(cm$canonical_jsonl_sha256))) stop("Canonical hash mismatch")
map <- fread(src$final_map,select=c("source","source_record_id","cluster_id"))
if(nrow(map)!=n||anyDuplicated(map[,.(source,source_record_id)])||uniqueN(map$cluster_id)!=k)
 stop("Final cluster map identity/count mismatch")
# Never stage alternative canonical text if replay differs.
if(!identical(sha(p("production_canonical","records.jsonl")),sha(src$canonical)))
 stop("Canonical production staging differs from verified replay")
dest <- list(
 final_map=file.path(out,"outputs","final","manifestation_cluster_map.csv"),
 final_pairs=file.path(out,"outputs","final","final_pair_decisions.csv"),
 final_summary=file.path(out,"outputs","final","summary.json"),
 final_aliases=file.path(out,"outputs","final","cluster_id_aliases.csv"),
 final_strips=file.path(out,"outputs","final","abstract_strip_actions.jsonl"),
 final_repairs=file.path(out,"outputs","final","cumulative_data_quality_repairs.jsonl"),
 canonical=file.path(out,"outputs","canonical","records.jsonl"),
 canonical_manifest=file.path(out,"outputs","canonical","canonical_manifest.json"),
 repair_audit=file.path(out,"outputs","canonical","data_quality_repair_application.jsonl")
)
for(nm in names(dest)){
 dir.create(dirname(dest[[nm]]),recursive=TRUE,showWarnings=FALSE)
 if(!isTRUE(file.copy(src[[nm]],dest[[nm]])))stop("Failed copying ",nm)
 if(!identical(sha(src[[nm]]),sha(dest[[nm]])))stop("Copy hash mismatch: ",nm)
}
# No attempt to synthesize LLM/human review state or an authorised publication flag.
manifest <- list(schema="w01-fast-staged-w01-handoff-v1",status="PASS_SHADOW_NO_PUBLICATION",
 source_manifestations=n,canonical_records=k,
 canonical_jsonl_sha256=sha(src$canonical),
 delta_replay_audit_sha256=sha(src$replay_audit),
 files=vapply(dest,sha,character(1)),publication_allowed=FALSE,
 workflow02_dispatch_allowed=FALSE,requires_explicit_production_integration=TRUE)
write_json(manifest,file.path(out,"handoff_manifest.json"),auto_unbox=TRUE,pretty=TRUE)
cat(sprintf("PASS: staged %d manifestations and %d canonical works for existing W01 file layout; NO publication or dispatch\n",n,k))
