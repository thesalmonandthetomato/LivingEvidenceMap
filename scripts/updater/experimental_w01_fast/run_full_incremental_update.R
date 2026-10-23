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
delta_writer<-arg("--delta-writer",optional=TRUE);if(is.null(delta_writer))delta_writer<-"legacy"
if(!delta_writer%in%c("legacy","direct"))stop("Unknown delta writer")
phase<-arg("--phase",optional=TRUE);if(is.null(phase))phase<-"all"
reviewed_root<-arg("--reviewed-root",optional=TRUE)
if(!is.null(reviewed_root)&&phase!="canonical")stop("Reviewed inputs may only enter canonical resume phase")
if(!phase%in%c("all","scoring","canonical","delta"))stop("Unsupported W01-Fast phase")
if(phase%in%c("all","scoring") && (dir.exists(output)||file.exists(output)))stop("Refuse overwrite output")
if(phase%in%c("canonical","delta") && !dir.exists(output))stop("Missing staged W01-Fast output; cannot resume")
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
if(phase%in%c("all","scoring")){
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
if(anyNA(d$rescored_classification))stop("Missing scientific classification; refusing incomplete review queue")
if(any(d$rescored_classification=="review")){
  # Preserve the existing Shiny review-case schema; never finalise or write a delta.
  review<-d[rescored_classification=="review"]
  required<-c("record_i","record_j","pair_key","rescored_rule","title_similarity","blocks")
  missing<-setdiff(required,names(review))
  if(length(missing))stop("Cannot generate authentic review queue; absent columns: ",paste(missing,collapse=", "))
  if(anyNA(review[,..required])||anyDuplicated(review$pair_key))
    stop("Ambiguous or incomplete Fast review cases")
  review_root<-file.path(output,"adjudication")
  dir.create(review_root,recursive=TRUE)
  review_csv<-file.path(review_root,"manual_review_pairs.csv")
  fwrite(review,review_csv)
  run("build_review_cases","scripts/updater/workflow_01_build_duplicate_adjudication_cases.R",
      c("--review-pairs",review_csv,"--metadata",metadata,
        "--union-dir",seed_root,"--output",file.path(review_root,"cases.jsonl")))
  source_run<-Sys.getenv("GITHUB_RUN_ID","experimental-fast")
  run("build_review_package","scripts/updater/workflow_01_build_human_review_package.R",
      c("--input",file.path(review_root,"cases.jsonl"),
        "--output-dir",file.path(review_root,"human_review_package"),
        "--source-run-id",source_run))
  write_report("AWAITING_HUMAN_REVIEW")
  cat(sprintf("PAUSE: %d unresolved duplicate pairs; Shiny-format human review package generated. No canonical changes, delta, publication or W02 dispatch.\\n",nrow(review)))
  quit(save="no",status=0L)
}
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
if(!file.exists(file.path(output,"cumulative_decisions.csv")) || !file.exists(file.path(output,"stable_decisions.csv")))stop("Scoring phase did not produce required verified decision files")
}
if(phase=="canonical"&&!is.null(reviewed_root)){
 # Resume only from the independently verified Shiny review adapter.
 verified_return<-file.path(reviewed_root,"shiny_return_verified.json")
 if(!file.exists(verified_return))stop("Missing independently verified Shiny return")
 vr<-fromJSON(verified_return)
 if(!identical(vr$status,"VERIFIED_SHINY_RETURN")||!identical(vr$production_publication_allowed,FALSE)||!identical(vr$workflow02_dispatch_allowed,FALSE))stop("Invalid Shiny return certificate")

 manifest_path<-file.path(reviewed_root,"resume_manifest.json")
 original_report<-file.path(output,"run_report.json")
 original_scores<-file.path(output,"rescored","rescored_sample.csv")
 reviewed_scores<-file.path(reviewed_root,"resolved_scoring.csv")
 required_review<-c(manifest_path,original_report,original_scores,reviewed_scores,
   file.path(reviewed_root,"stable_decisions.csv"),
   file.path(reviewed_root,"cumulative_decisions.csv"),
   file.path(reviewed_root,"cumulative_decisions.csv.audit.json"))
 if(any(!file.exists(required_review)))stop("Missing verified human review resume checkpoint")
 mr<-fromJSON(manifest_path);original_status<-fromJSON(original_report)$status
 if(!identical(original_status,"AWAITING_HUMAN_REVIEW")||
    !identical(mr$status,"VALIDATED_RESUME_READY")||
    !identical(mr$publication_allowed,FALSE)||
    !identical(mr$original_scoring_sha256,digest(file=original_scores,algo="sha256"))||
    !identical(mr$resolved_scoring_sha256,digest(file=reviewed_scores,algo="sha256"))||
    !identical(mr$queue_sha256,vr$queue_sha256)||
    !identical(mr$review_repairs_sha256,vr$repair_sha256)||
    !identical(mr$review_repairs_sha256,digest(file=file.path(reviewed_root,"verified_new_repairs.jsonl"),algo="sha256")))
   stop("Reviewed continuation does not match immutable Fast scoring checkpoint")
 if(any(file.exists(file.path(output,c("stable_decisions.csv","cumulative_decisions.csv",
   "cumulative_decisions.csv.audit.json")))))stop("Existing continuation; refuse overwrite")
 for(nm in c("stable_decisions.csv","cumulative_decisions.csv","cumulative_decisions.csv.audit.json")){
    if(!file.copy(file.path(reviewed_root,nm),file.path(output,nm)))stop("Cannot stage ",nm)
 }
}
if(phase=="canonical"&&!is.null(reviewed_root)){
 # Production merger is the only authority for cumulative repair and strip provenance.
 # Keep source ledger inputs untouched and use isolated merged outputs downstream.
 merged_root<-file.path(output,"reviewed_directives")
 if(dir.exists(merged_root))stop("Existing reviewed directive checkpoint; refuse overwrite")
 dir.create(merged_root)
 empty_new_strips<-file.path(merged_root,"new_strips.jsonl")
 file.create(empty_new_strips)
 run("merge_verified_review_repairs","scripts/updater/workflow_01_merge_cumulative_repairs.R",
 c("--previous-repairs",repairs,
 "--new-repairs",file.path(reviewed_root,"verified_new_repairs.jsonl"),
 "--previous-strips",strips,"--new-strips",empty_new_strips,
 "--output-repairs",file.path(merged_root,"cumulative_repairs.jsonl"),
 "--output-strips",file.path(merged_root,"cumulative_strips.jsonl")))
 repairs<-file.path(merged_root,"cumulative_repairs.jsonl")
 strips<-file.path(merged_root,"cumulative_strips.jsonl")
}
if(phase%in%c("all","canonical")){
if(!file.exists(file.path(output,"cumulative_decisions.csv")) || !file.exists(file.path(output,"stable_decisions.csv"))) stop("Missing scoring checkpoint")
run("clusters",file.path(base,"update_clusters_by_identity.R"),
 c("--prior-map",prior,"--metadata",metadata,
 "--incremental-decisions",file.path(output,"stable_decisions.csv"),
 "--output-dir",file.path(output,"clusters")))
next_map<-file.path(output,"clusters","identity_cluster_map.csv")
run("identify_affected",file.path(base,"identify_affected_works.R"),
 c("--prior-map",prior,"--next-map",next_map,
 "--repairs",repairs,"--output-dir",file.path(output,"affected")))
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
 "--repair-audit",file.path(output,"repair_audit.jsonl"),
 "--previous-canonical-manifest",file.path(previous_root,"canonical","canonical_manifest.json")))
if(!file.exists(file.path(output,"production_canonical","canonical_manifest.json")))stop("Canonical phase did not produce production manifest")
}
if(phase%in%c("all","delta") || (phase=="canonical"&&!is.null(reviewed_root))){
if(!file.exists(file.path(output,"production_canonical","canonical_manifest.json")) || !file.exists(file.path(output,"production_final","final_pair_decisions.csv")))stop("Missing canonical checkpoint")
# Validate persistence using the unmodified W01 delta generator and replay engine.
if(delta_writer=="direct"){
 run("build_direct_delta",file.path(base,"write_direct_delta.R"),
 c("--previous-root",previous_root,"--current-seed-root",seed_root,
 "--current-final-root",file.path(output,"production_final"),
 "--current-canonical",file.path(output,"production_canonical","records.jsonl"),
 "--current-canonical-manifest",file.path(output,"production_canonical","canonical_manifest.json"),
 "--previous-pointer",previous_pointer,
 "--new-decisions",if(is.null(reviewed_root)) file.path(output,"rescored","rescored_sample.csv") else file.path(reviewed_root,"resolved_scoring.csv"),
 "--affected-map",file.path(output,"canonical_scope","affected_cluster_map.csv"),
 "--canonical-changes",file.path(output,"changed_canonical.jsonl"),
 "--affected-works",file.path(output,"affected","affected_works.csv"),
 "--output-dir",file.path(output,"delta"),"--run-id","w01-fast-frozen-shadow"))
}else{
run("build_delta","scripts/updater/workflow_01_build_delta.R",
 c("--previous-root",previous_root,"--current-seed-root",seed_root,
 "--current-final-root",file.path(output,"production_final"),
 "--current-canonical",file.path(output,"production_canonical","records.jsonl"),
 "--current-canonical-manifest",file.path(output,"production_canonical","canonical_manifest.json"),
 "--previous-pointer",previous_pointer,
 "--repair-audit",file.path(output,"production_canonical","data_quality_repair_application.jsonl"),
 "--repair-ledger",repairs,
 "--output-dir",file.path(output,"delta"),"--run-id","w01-fast-frozen-shadow"))
}
run("replay_delta","scripts/updater/workflow_01_replay_delta.R",
 c("--previous-root",previous_root,"--delta-dir",file.path(output,"delta"),
 "--output-root",file.path(output,"replayed")))

write_report("PASS_SHADOW_NO_PUBLICATION")
}
cat("PASS: isolated W01-Fast complete output contract, delta build and replay; NO publication or W02 dispatch\\n")
