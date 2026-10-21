#!/usr/bin/env Rscript
# Scientific diagnostic: run the UNMODIFIED production base scorer on recovered
# October candidate manifestation abstracts. Not yet decision/route parity.
suppressPackageStartupMessages({library(data.table);library(jsonlite)})
input <- "october_abstract_recovery/candidate_manifestation_abstracts.json"
if(!file.exists(input))stop("No recovered candidate abstracts")
a <- fromJSON(input,simplifyVector=FALSE)
meta_path <- "reference/outputs/workflow01_candidates/normalised_metadata.csv"
candidate_path <- "reference/outputs/workflow01_candidates/all_candidate_pairs.csv"
if(!all(file.exists(c(meta_path,candidate_path))))stop("Missing frozen scoring metadata")
if(length(a)!=1738L)stop("Recovered candidate manifestation count has changed")
if(dir.exists("october_recovered_scoring"))stop("Refuse to overwrite scoring output")
dir.create("october_recovered_scoring")
dir.create("october_recovered_scoring/upstream")
keys <- function(s,id)paste0(nchar(s,type="bytes"),":",s,nchar(id,type="bytes"),":",id)
m <- fread(meta_path,colClasses=list(character=c("source","source_record_id")))
cand <- fread(candidate_path)
ids <- unique(c(cand$record_i,cand$record_j))
t <- m[match(ids,idx)]
if(anyNA(t$source))stop("Invalid frozen candidate index")
want <- keys(t$source,t$source_record_id)
got <- vapply(a,function(z)keys(z$source,z$source_record_id),character(1))
if(anyDuplicated(got)||!setequal(want,got))stop("Recovered identities do not match frozen candidates")
sources <- list()
for(src in unique(vapply(a,function(z)as.character(z$source),character(1)))){
 rows <- Filter(function(z)identical(z$source,src),a)
 file <- file.path("october_recovered_scoring/upstream",paste0(src,"_records_for_deduplication.jsonl"))
 convert <- function(z){
   abstract <- z$abstract
   if(identical(src,"lens")){
     list(lens=list(raw_payload=list(abstract=abstract)),
          identity=list(lens_id=z$source_record_id),
          canonical=list(abstract=abstract))
   }else{
     provider <- switch(src,agricola="agricola_via_europe_pmc",wos="wos_starter",src)
     list(source=list(provider=provider),
          sidecar_identity=list(sidecar_record_id=z$source_record_id),
          mapped_fields=list(abstract=abstract))
   }
 }
 writeLines(vapply(rows,function(z)toJSON(convert(z),auto_unbox=TRUE,null="null"),character(1)),file,useBytes=TRUE)
 sources[[src]]<-list(file)
}
write_json(list(schema="living-evidence-map-workflow01-source-inputs-v1",sources=sources),
 "october_recovered_scoring/upstream/source_inputs.json",auto_unbox=TRUE,pretty=TRUE)
script <- "scripts/updater/workflow_01_deduplication_incremental_score.R"
args <- c(script,"--input-dir","reference/outputs/workflow01_candidates",
 "--upstream-dir","october_recovered_scoring/upstream",
 "--output-dir","october_recovered_scoring/base",
 "--target-n","2000","--sample-key","october-w01-fast-frozen-parity")
result <- suppressWarnings(system2(file.path(R.home("bin"),"Rscript"),args,stdout=TRUE,stderr=TRUE))
status <- attr(result,"status");if(is.null(status))status<-0L
if(status!=0L)stop("Unmodified base scoring failed: ",paste(tail(result,20L),collapse=" | "))
scored <- fread("october_recovered_scoring/base/scored_sample.csv")
if(nrow(scored)!=1719L)stop("Expected 1719 independently scored pairs")
write_json(list(schema="w01-fast-october-independent-base-scoring-v1",
 candidate_pairs=1719L,source_manifestations=length(a),base_scored_pairs=nrow(scored),
 classification_counts=as.list(table(scored$classification)),
 complete_production_decision_parity=FALSE,route_parity=FALSE),
 "october_recovered_scoring/report.json",auto_unbox=TRUE,pretty=TRUE)
cat("PASS: original production base scorer independently scored 1719 October pairs from recovered canonical abstract text\\n")

# Apply the same unchanged deterministic post-score rescorer that production uses.
rescore_args<-c("scripts/updater/workflow_01_deduplication_identifier_rescore.R",
 "--input-dir","october_recovered_scoring/base",
 "--output-dir","october_recovered_scoring/rescore",
 "--source-run-id","39400566861")
rescore_log<-suppressWarnings(system2(file.path(R.home("bin"),"Rscript"),rescore_args,stdout=TRUE,stderr=TRUE))
rescore_status<-attr(rescore_log,"status");if(is.null(rescore_status))rescore_status<-0L
if(rescore_status!=0L)stop("Unmodified rescorer failed: ",paste(tail(rescore_log,30L),collapse=" | "))
rescore_data<-fread("october_recovered_scoring/rescore/rescored_sample.csv")
if(nrow(rescore_data)!=1719L)stop("Expected all 1719 candidates after deterministic rescoring")
cat("PASS: unchanged deterministic rescorer independently processed 1719 October candidates\\n")
