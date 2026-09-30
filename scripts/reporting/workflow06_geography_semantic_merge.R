#!/usr/bin/env Rscript
suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
  library(jsonlite)
})

args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag, default=NULL){
  i <- match(flag,args)
  if(is.na(i)) return(default)
  if(i==length(args)) stop(sprintf("Missing value after %s",flag),call.=FALSE)
  args[[i+1L]]
}
input_dir <- arg("--input-dir")
out_dir <- arg("--output-dir","outputs/workflow06_geography_production_merged")
expected_shards <- as.integer(arg("--expected-shards","20"))
expected_records <- as.integer(arg("--expected-records","0"))
if(is.null(input_dir)||!dir.exists(input_dir)) stop("--input-dir is required")
if(is.na(expected_shards)||expected_shards<1L)stop("--expected-shards must be >=1",call.=FALSE)
if(is.na(expected_records)||expected_records<0L)stop("--expected-records must be >=0",call.=FALSE)
dir.create(out_dir,recursive=TRUE,showWarnings=FALSE)

files <- list.files(input_dir,pattern="geography_results\\.csv$",recursive=TRUE,full.names=TRUE)
if(length(files)!=expected_shards) stop(sprintf("Expected %d shard CSVs, found %d",expected_shards,length(files)))
x <- bind_rows(lapply(files,read_csv,show_col_types=FALSE,progress=FALSE)) |> arrange(record_sequence)
if(expected_records>0L&&nrow(x)!=expected_records)stop(sprintf("Expected %d screened records, found %d",expected_records,nrow(x)),call.=FALSE)
if(anyDuplicated(x$record_id)||anyDuplicated(x$record_sequence))stop("Merged geography identity/sequence invariant failed",call.=FALSE)

jsonl <- list.files(input_dir,pattern="geography_results\\.jsonl$",recursive=TRUE,full.names=TRUE)
if(length(jsonl)!=expected_shards) stop(sprintf("Expected %d shard JSONL files, found %d",expected_shards,length(jsonl)))
json_lines <- unlist(lapply(jsonl,readLines,warn=FALSE,encoding="UTF-8"),use.names=FALSE)
json_lines <- json_lines[nzchar(trimws(json_lines))]
if(length(json_lines)!=nrow(x)) stop(sprintf("Expected %d JSONL records, found %d",nrow(x),length(json_lines)))
ids <- vapply(json_lines,function(z) as.character(fromJSON(z,simplifyVector=FALSE)$record_id),character(1))
if(anyDuplicated(ids)||!setequal(ids,x$record_id)) stop("JSONL record IDs do not match merged CSV")

write_csv(x,file.path(out_dir,"geography_semantic_final.csv"),na="")
write_csv(x |> filter(geography_status=="UNRESOLVED"),file.path(out_dir,"geography_unresolved.csv"),na="")
write_csv(x |> filter(!evidence_all_grounded),file.path(out_dir,"geography_ungrounded_evidence.csv"),na="")
write_csv(x |> filter(llm_failed),file.path(out_dir,"geography_llm_failures.csv"),na="")
write_csv(x |> filter(discrepancy_type!="exact_agreement"),file.path(out_dir,"geography_deterministic_qc_discrepancies.csv"),na="")
writeLines(json_lines,file.path(out_dir,"geography_semantic_final.jsonl"),useBytes=TRUE)

patterns <- x |> count(discrepancy_type,name="n") |> mutate(pct=100*n/nrow(x)) |> arrange(desc(n))
statuses <- x |> count(geography_status,name="n") |> mutate(pct=100*n/nrow(x))
write_csv(patterns,file.path(out_dir,"discrepancy_patterns.csv"),na="")
write_csv(statuses,file.path(out_dir,"geography_status_counts.csv"),na="")

sum_files<-list.files(input_dir,pattern="summary\\.json$",recursive=TRUE,full.names=TRUE)
if(length(sum_files)!=expected_shards)stop(sprintf("Expected %d shard summaries, found %d",expected_shards,length(sum_files)),call.=FALSE)
shard_summaries<-lapply(sum_files,fromJSON,simplifyVector=FALSE)
prompt_shas<-unique(vapply(shard_summaries,function(z)as.character(z$prompt_sha256),character(1)))
if(length(prompt_shas)!=1L)stop("Prompt SHA mismatch across W06 shards",call.=FALSE)
if(sum(vapply(shard_summaries,function(z)as.integer(z$n),integer(1)))!=nrow(x))stop("Shard summary record counts do not sum to merged rows",call.=FALSE)

summary <- list(
  records=nrow(x),
  model="gpt-5.6-luna",
  reasoning="low",
  prompt_sha256=prompt_shas[[1L]],
  resolved_n=sum(x$geography_status=="RESOLVED"),
  none_n=sum(x$geography_status=="NONE"),
  unresolved_n=sum(x$geography_status=="UNRESOLVED"),
  evidence_ungrounded_n=sum(!x$evidence_all_grounded),
  llm_failures_n=sum(x$llm_failed),
  deterministic_exact_agreement_n=sum(x$exact_agreement),
  deterministic_exact_agreement_pct=100*mean(x$exact_agreement),
  qc_discrepancies_n=sum(x$discrepancy_type!="exact_agreement")
)
writeLines(toJSON(summary,auto_unbox=TRUE,pretty=TRUE),file.path(out_dir,"summary.json"))
cat(toJSON(summary,auto_unbox=TRUE,pretty=TRUE),"\n")
print(statuses)
print(patterns)
