#!/usr/bin/env Rscript
# Non-publishing assembly of W01-Fast final/canonical outputs alongside authoritative
# previous-state, source-union, review and already-verified delta provenance.
suppressPackageStartupMessages({library(jsonlite);library(digest)})
a<-commandArgs(trailingOnly=TRUE)
arg<-function(k){i<-match(k,a);if(is.na(i)||i==length(a))stop("Missing ",k);a[[i+1L]]}
fast<-arg("--fast-root");previous<-arg("--previous-root")
seed<-arg("--current-seed-root");repairs<-arg("--normalised-human-repairs")
out<-arg("--output-root")
if(file.exists(out)||dir.exists(out))stop("Refusing to overwrite shadow output")
p<-function(...)file.path(fast,...)
must<-c(file.path(previous,"workflow01_full_five_source","summary.json"),
 file.path(previous,"workflow01_full_five_source","manifestation_cluster_map.csv"),
 file.path(previous,"canonical","records.jsonl"),
 file.path(seed,"source_inputs.json"),repairs,
 p("delta","delta_manifest.json"),p("replayed","workflow01_delta_replay_audit.json"))
if(any(!file.exists(must)))stop("Missing authoritative previous-state, source-union, human or delta inputs")
stage<-file.path(out,"_staged")
# Validate the existing adapter before copying anything else.
cmd<-c("scripts/updater/experimental_w01_fast/stage_production_handoff.R",
 "--fast-root",fast,"--output-root",stage)
status<-system2(file.path(R.home("bin"),"Rscript"),cmd)
if(!identical(as.integer(status),0L))stop("Staging verified W01-Fast result failed")
copy_tree<-function(src,dst){
 if(!dir.exists(src))stop("Missing authoritative directory: ",src)
 if(dir.exists(dst)||file.exists(dst))stop("Refusing overwrite: ",dst)
 dir.create(dirname(dst),recursive=TRUE,showWarnings=FALSE)
 if(!file.copy(src,dirname(dst),recursive=TRUE))stop("Cannot copy: ",src)
 if(basename(src)!=basename(dst)){
   if(!file.rename(file.path(dirname(dst),basename(src)),dst))
     stop("Cannot place: ",dst)
 }
}
# Canonicalised shadow is derived from a validated adapter, never directly from
# an ad-hoc rewrite of production outputs.
dir.create(out,recursive=TRUE,showWarnings=FALSE)
copy_tree(previous,file.path(out,"previous_state"))
copy_tree(seed,file.path(out,"outputs","workflow01_union"))
dir.create(file.path(out,"outputs","human_gate","normalised"),recursive=TRUE)
dst_repairs<-file.path(out,"outputs","human_gate","normalised","data_quality_repairs.normalised.jsonl")
if(!file.copy(repairs,dst_repairs))stop("Cannot copy original review repair ledger")
copy_tree(p("delta"),file.path(out,"outputs","delta"))
copy_tree(p("replayed"),file.path(out,"outputs","replayed"))
copy_tree(file.path(stage,"outputs","final"),file.path(out,"outputs","final"))
copy_tree(file.path(stage,"outputs","canonical"),file.path(out,"outputs","canonical"))
# The production checksum transfer contract uses the exact files supplied
# to the finalisation job; no earlier checksum file is impersonated.
targets<-c("previous_state/workflow01_full_five_source/summary.json",
 "outputs/workflow01_union/source_inputs.json",
 "outputs/final/summary.json","outputs/final/manifestation_cluster_map.csv",
 "outputs/canonical/records.jsonl","outputs/canonical/canonical_manifest.json")
sha<-function(x)digest(file=file.path(out,x),algo="sha256",serialize=FALSE)
writeLines(paste0(vapply(targets,sha,character(1)),"  ",targets),
 file.path(out,"outputs","workflow01_stage_canonicalise_checksums.txt"))
# Staging is explicitly a shadow; no write-capable publication outputs.
system2(file.path(R.home("bin"),"Rscript"),
 c("scripts/updater/experimental_w01_fast/audit_publication_contract.R","--root",out)) -> code
if(!identical(as.integer(code),0L))stop("Publication contract shadow audit rejected handoff")
manifest<-list(schema="w01-fast-publication-shadow-v1",status="PASS_SHADOW_NO_PUBLICATION",
 publication_allowed=FALSE,workflow02_dispatch_allowed=FALSE,
 original_previous_state_sha256=sha(targets[[1L]]),
 source_manifest_sha256=sha(targets[[2L]]),
 repair_ledger_sha256=sha("outputs/human_gate/normalised/data_quality_repairs.normalised.jsonl"))
write_json(manifest,file.path(out,"publication_shadow_manifest.json"),pretty=TRUE,auto_unbox=TRUE)
cat("PASS: complete immutable-source publication shadow staged and contract audited; NO publication or W02\n")
