#!/usr/bin/env Rscript
# Fail-closed, read-only W01-Fast acceptance gate. Never runs or deploys W01.
suppressPackageStartupMessages(library(jsonlite))
args <- commandArgs(trailingOnly=TRUE)
arg <- function(k,default=NULL){i<-match(k,args);if(is.na(i))default else if(i==length(args))stop(paste("Missing",k))else args[[i+1L]]}
evidence <- arg("--evidence-dir", "scripts/updater/experimental_w01_fast/evidence")
output <- arg("--output")
if(is.null(output))stop("Required: --output")
if(file.exists(output))stop("Refusing to overwrite readiness report")
tests <- c("candidate_identity_and_block_parity","independent_classification_parity",
 "identifier_assist_rule_and_route_parity","affected_existing_canonical_parity",
 "unchanged_historical_byte_parity","checkpoint_recovery_end_to_end",
 "frozen_w00_shadow_run","full_pipeline_runtime_and_memory")
records<-lapply(tests,function(id){
 path<-file.path(evidence,paste0(id,".json"))
 if(!file.exists(path))return(list(test=id,passed=FALSE,reason="missing independent acceptance evidence"))
 z<-tryCatch(fromJSON(path,simplifyVector=FALSE),error=function(err)NULL)
 if(is.null(z)||!is.list(z)||!identical(z$test,id)||
    !identical(z$passed,TRUE)||is.null(z$run_url)||!nzchar(as.character(z$run_url))||
    !grepl("^https://github\\.com/thesalmonandthetomato/LivingEvidenceMap/actions/runs/[0-9]+$",z$run_url)){
  return(list(test=id,passed=FALSE,reason="invalid, failed or non-verifiable evidence"))
 }
 list(test=id,passed=TRUE,run_url=z$run_url)
})
passed<-vapply(records,function(z)isTRUE(z$passed),logical(1))
shadow_ok<-all(passed[seq_len(6L)])
full_ok<-all(passed)
dir.create(dirname(output),recursive=TRUE,showWarnings=FALSE)
write_json(list(schema="w01-fast-run-readiness-v1",ready_for_production_migration=FALSE,
 ready_for_full_frozen_w00_shadow_run=shadow_ok,
 scientific_and_performance_evidence_complete=full_ok,tests=records,
 note="An evidence checklist does not itself verify scientific correctness; inspect original audit artefacts."),
 output,auto_unbox=TRUE,pretty=TRUE)
cat(sprintf("W01-Fast read-only acceptance gates: %d/%d evidenced. Frozen W00 shadow readiness: %s\\n",
 sum(passed),length(records),shadow_ok))
if(!shadow_ok)quit(save="no",status=2L)
