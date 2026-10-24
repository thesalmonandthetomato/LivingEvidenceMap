#!/usr/bin/env Rscript
# W08b offline candidate post-processing. Conservative, no W01 writes.
# Usage: postprocess_candidates.R <w01.jsonl> <candidate_ids.csv> <metadata.jsonl> <strategy.json> <output_dir>
suppressPackageStartupMessages(library(jsonlite))
a<-commandArgs(trailingOnly=TRUE)
if(length(a)!=5L)stop("Usage: postprocess_candidates.R w01.jsonl provider_candidate_ids.csv lens_candidate_metadata.jsonl strategy.json output_dir")
for(f in a[1:4])if(!file.exists(f))stop("Missing input: ",f)
out<-a[[5]];dir.create(out,recursive=TRUE,showWarnings=FALSE)
run<-function(script,args){
 result<-system2("Rscript",c(shQuote(script),vapply(args,shQuote,character(1))))
 if(result!=0L)stop("Post-processing failed at ",script,"; exit ",result)
}
pre<-file.path(out,"provider_identity")
run("scripts/workflow08b/filter_existing_w01.R",c(a[[1]],a[[2]],pre))
idx<-file.path(out,"historical_doi")
run("scripts/workflow08b/index_w01_dois.R",c(a[[1]],idx))
screen<-file.path(out,"strategy_filter.csv")
audit<-file.path(out,"strategy_filter_audit.json")
run("scripts/workflow08b/filter_original_strategy.R",c(a[[3]],a[[4]],screen,audit))
reconciled<-file.path(out,"reconciled")
run("scripts/workflow08b/reconcile_lens_candidates.R",c(
 file.path(pre,"candidate_identity_precheck.csv"),a[[3]],screen,reconciled,
 file.path(idx,"historical_doi_index.csv")))
data<-read.csv(file.path(reconciled,"reconciliation.csv"),stringsAsFactors=FALSE)
counts<-as.list(table(data$reconciliation_status))
# An unresolved identifier must never be treated as an eligible screening case.
eligible<-if(nrow(data))sum(data$reconciliation_status=="new_doi_requires_other_identity_checks")else 0L
info<-list(schema="workflow08b-offline-postprocess-v1",
 input_provider_candidates=nrow(data),
 potentially_new_pending_secondary_identity_checks=eligible,
 reconciliation_statuses=counts,automatic_W01_handoff=FALSE)
writeLines(toJSON(info,auto_unbox=TRUE,pretty=TRUE),file.path(out,"postprocess_summary.json"))
cat("PASS: W08b metadata strategy DOI and historical W01 crosschecks integrated; W01 handoff disabled\n")
