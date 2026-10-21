#!/usr/bin/env Rscript
# Isolated end-to-end W01-Fast update. Never publishes, dispatches, or changes prior state.
# All inputs must be frozen snapshots and original deduplication source JSONL streams.
suppressPackageStartupMessages({library(data.table);library(jsonlite);library(digest)})
args<-commandArgs(trailingOnly=TRUE)
arg<-function(k,optional=FALSE){i<-match(k,args);if(is.na(i)){if(optional)return(NULL);stop("Missing ",k)};if(i==length(args))stop("Missing value ",k);args[[i+1L]]}
metadata<-arg("--metadata");prior<-arg("--prior-map")
source_manifest<-arg("--source-manifest");prior_canonical<-arg("--prior-canonical")
strips<-arg("--strip-actions");repairs<-arg("--repairs")
previous_decisions<-arg("--previous-decisions");previous_root<-arg("--previous-root")
previous_pointer<-arg("--previous-pointer");seed_root<-arg("--current-seed-root")
output<-arg("--output-dir")
if(dir.exists(output)||file.exists(output))stop("Refuse overwrite output")
inputs<-c(metadata,prior,source_manifest,prior_canonical,strips,repairs,previous_decisions,previous_pointer)
if(any(!dir.exists(c(previous_root,seed_root)))||any(!file.exists(inputs)))stop("Required original inputs missing; refusing partial/fabricated canonical output")
m<-fread(metadata,colClasses=list(character=c("source","source_record_id")))
prev<-fread(prior,colClasses=list(character=c("source","source_record_id","cluster_id")))
if(!all(c("idx","source","source_record_id")%in%names(m))||
 !all(c("source","source_record_id","cluster_id")%in%names(prev))||
 anyDuplicated(m[,.(source,source_record_id)])||
 anyDuplicated(prev[,.(source,source_record_id)]))stop("Invalid source identities")
if(!identical(as.integer(m$idx),seq_len(nrow(m))))stop("Non-contiguous metadata index")
if(nrow(prev)>nrow(m))stop("Prior state larger than input")
im<-fromJSON(source_manifest,simplifyVector=FALSE)
if(!identical(im$schema,"living-evidence-map-workflow01-source-inputs-v1")||
 is.null(names(im$sources)))stop("Invalid original source manifest")
src_paths<-vapply(im$sources,function(x)as.character(x[[1L]]),character(1))
if(any(!file.exists(src_paths)))stop("Original source JSONL missing; fail closed")
dir.create(output,recursive=TRUE)
base<-"scripts/updater/experimental_w01_fast"
stages<-list()
write_report<-function(stage="running"){
 write_json(list(schema="w01-fast-isolated-update-v1",status=stage,
 prior_manifestations=nrow(prev),new_manifestations=nrow(m)-nrow(prev),
 stage_timings=stages,production_publication_allowed=FALSE),
 file.path(output,"run_report.json"),pretty=TRUE,auto_unbox=TRUE)
}
run<-function(name,script,opts){
 now<-proc.time()[["elapsed"]]
 z<-suppressWarnings(system2(file.path(R.home("bin"),"Rscript"),c(script,opts),stdout=TRUE,stderr=TRUE))
 status<-attr(z,"status");if(is.null(status))status<-0L
 elapsed<-round(proc.time()[["elapsed"]]-now,3)
 stages[[name]]<<-list(seconds=elapsed,status=as.integer(status))
 write_report(if(status==0)"running" else paste0("FAILED_",name))
 cat(sprintf("STAGE %s: status=%d elapsed=%.3f seconds\\n",name,status,elapsed))
 flush.console()
 if(status!=0L)stop(sprintf("Stage %s failed: %s",name,paste(tail(z,16L),collapse=" | ")))
}
# Raw metadata and source files stay untouched; work only in the isolated output root.
candidate<-file.path(output,"candidates");dir.create(candidate)
file.copy(metadata,file.path(candidate,"normalised_metadata.csv"))
nold<-as.character(nrow(prev))
run("exact",file.path(base,"build_exact_block_index.R"),
 c("--metadata",metadata,"--prior-n",nold,"--output-dir",file.path(output,"exact")))
run("fuzzy",file.path(base,"build_fuzzy_candidates.R"),
 c("--metadata",metadata,"--prior-n",nold,"--output-dir",file.path(output,"fuzzy")))
run("combine",file.path(base,"combine_candidates.R"),
 c("--exact",file.path(output,"exact","exact_block_candidates.csv"),
 "--fuzzy",file.path(output,"fuzzy","fuzzy_candidates.csv"),
 "--output",file.path(candidate,"all_candidate_pairs.csv")))
# The preserved source manifest is the full ORIGINAL input, not a reconstruction
# from already resolved reference decisions. Staging adapter is not permitted to
# silently omit texts or invent new identifiers.
upstream<-file.path(output,"upstream");dir.create(upstream)
file.copy(source_manifest,file.path(upstream,"source_inputs.json"))
run("base_scoring","scripts/updater/workflow_01_deduplication_incremental_score.R",
 c("--input-dir",candidate,"--upstream-dir",upstream,
 "--output-dir",file.path(output,"scored"),"--target-n","2000"))
run("rescoring","scripts/updater/workflow_01_deduplication_identifier_rescore.R",
 c("--input-dir",file.path(output,"scored"),"--output-dir",file.path(output,"rescored")))
d<-fread(file.path(output,"rescored","rescored_sample.csv"))
if(any(!d$rescored_classification%in%c("duplicate","unresolved","review")))stop("Unknown scoring classification")
if(anyNA(d$rescored_classification)||any(d$rescored_classification=="review"))stop("Unresolved scientific review cases; never merge automatically")
l<-match(d$record_i,m$idx);rr<-match(d$record_j,m$idx)
if(anyNA(l)||anyNA(rr))stop("Decision identity mismatch")
stable<-data.table(source_i=m$source[l],source_record_id_i=m$source_record_id[l],
 source_j=m$source[rr],source_record_id_j=m$source_record_id[rr],
 rescored_classification=d$rescored_classification,rescored_rule=d$rescored_rule,
 review_route=d$review_route)
fwrite(stable,file.path(output,"stable_decisions.csv"))
run("stage_cumulative_ledger",file.path(base,"stage_production_pair_ledger.R"),
 c("--previous-decisions",previous_decisions,
 "--previous-map",prior,
 "--scored-decisions",file.path(output,"rescored","rescored_sample.csv"),
 "--metadata",metadata,"--output",file.path(output,"cumulative_decisions.csv")))
run("clusters",file.path(base,"update_clusters_by_identity.R"),
 c("--prior-map",prior,"--metadata",metadata,
 "--incremental-decisions",file.path(output,"stable_decisions.csv"),
 "--output-dir",file.path(output,"clusters")))
next_map<-file.path(output,"clusters","identity_cluster_map.csv")
run("identify_affected",file.path(base,"identify_affected_works.R"),
 c("--prior-map",prior,"--next-map",next_map,"--output-dir",file.path(output,"affected")))
run("stage_canonical_scope",file.path(base,"prepare_affected_canonical_map.R"),
 c("--successor-map",next_map,"--affected-works",file.path(output,"affected","affected_works.csv"),
 "--output-dir",file.path(output,"canonical_scope")))
affected_map<-file.path(output,"canonical_scope","affected_cluster_map.csv")
run("select_source_records",file.path(base,"filter_canonical_source_inputs.R"),
 c("--affected-cluster-map",affected_map,"--input-manifest",source_manifest,
 "--output-dir",file.path(output,"filtered")))
run("select_directives",file.path(base,"filter_canonical_directives.R"),
 c("--affected-cluster-map",affected_map,"--strip-actions",strips,
 "--data-quality-repairs",repairs,"--output-dir",file.path(output,"directives")))
run("canonicalise","scripts/updater/workflow_01_build_canonical_jsonl.R",
 c("--cluster-map",affected_map,
 "--input-manifest",file.path(output,"filtered","filtered_source_inputs.json"),
 "--run-id","w01-fast-frozen-shadow",
 "--strip-actions",file.path(output,"directives","strip_actions.jsonl"),
 "--data-quality-repairs",file.path(output,"directives","data_quality_repairs.jsonl"),
 "--output",file.path(output,"changed_canonical.jsonl"),
 "--manifest",file.path(output,"changed_canonical_manifest.json"),
 "--repair-audit",file.path(output,"repair_audit.jsonl"),
 "--previous-canonical-manifest",file.path(previous_root,"canonical","canonical_manifest.json")))
run("recombine",file.path(base,"recombine_canonical_jsonl.R"),
 c("--prior",prior_canonical,"--changed",file.path(output,"changed_canonical.jsonl"),
 "--affected-works",file.path(output,"affected","affected_works.csv"),
 "--output-dir",file.path(output,"final")))
# Assemble exact production file paths without publishing or updating pointer registries.
run("stage_final_state",file.path(base,"stage_production_final_map.R"),
 c("--metadata",metadata,"--clusters",next_map,
 "--final-decisions",file.path(output,"cumulative_decisions.csv"),
 "--prior-map",prior,"--output-dir",file.path(output,"production_final")))
if(!file.copy(strips,file.path(output,"production_final","abstract_strip_actions.jsonl")) ||
 !file.copy(repairs,file.path(output,"production_final","cumulative_data_quality_repairs.jsonl")))
 stop("Cannot retain cumulative provenance in final state")
run("stage_canonical_contract",file.path(base,"stage_production_canonical_contract.R"),
 c("--cluster-map",file.path(output,"production_final","manifestation_cluster_map.csv"),
 "--canonical",file.path(output,"final","canonical.jsonl"),
 "--output-dir",file.path(output,"production_canonical"),
 "--run-id","w01-fast-frozen-shadow",
 "--strip-actions",file.path(output,"production_final","abstract_strip_actions.jsonl"),
 "--repair-ledger",file.path(output,"production_final","cumulative_data_quality_repairs.jsonl"),
 "--repair-audit",file.path(output,"repair_audit.jsonl")))
# Validate persistence using the unmodified W01 delta generator and replay engine.
run("build_delta","scripts/updater/workflow_01_build_delta.R",
 c("--previous-root",previous_root,"--current-seed-root",seed_root,
 "--current-final-root",file.path(output,"production_final"),
 "--current-canonical",file.path(output,"production_canonical","records.jsonl"),
 "--current-canonical-manifest",file.path(output,"production_canonical","canonical_manifest.json"),
 "--previous-pointer",previous_pointer,
 "--repair-audit",file.path(output,"production_canonical","data_quality_repair_application.jsonl"),
 "--repair-ledger",repairs,
 "--output-dir",file.path(output,"delta"),"--run-id","w01-fast-frozen-shadow"))
run("replay_delta","scripts/updater/workflow_01_replay_delta.R",
 c("--previous-root",previous_root,"--delta-dir",file.path(output,"delta"),
 "--output-root",file.path(output,"replayed")))

write_report("PASS_SHADOW_NO_PUBLICATION")
cat("PASS: isolated W01-Fast complete output contract, delta build and replay; NO publication or W02 dispatch\\n")
