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
out_dir <- arg("--output-dir","outputs/workflow05_geography_production_merged")
if(is.null(input_dir)||!dir.exists(input_dir)) stop("--input-dir is required")
dir.create(out_dir,recursive=TRUE,showWarnings=FALSE)

files <- list.files(input_dir,pattern="geography_results\\.csv$",recursive=TRUE,full.names=TRUE)
if(length(files)!=20L) stop(sprintf("Expected 20 shard CSVs, found %d",length(files)))
x <- bind_rows(lapply(files,read_csv,show_col_types=FALSE)) |> arrange(record_sequence)
stopifnot(nrow(x)==19407L,!anyDuplicated(x$record_id),!anyDuplicated(x$record_sequence))
if(!identical(sort(x$record_sequence),seq_len(19407L))) stop("record_sequence is not exactly 1:19407")

jsonl <- list.files(input_dir,pattern="geography_results\\.jsonl$",recursive=TRUE,full.names=TRUE)
if(length(jsonl)!=20L) stop(sprintf("Expected 20 shard JSONL files, found %d",length(jsonl)))
json_lines <- unlist(lapply(jsonl,readLines,warn=FALSE,encoding="UTF-8"),use.names=FALSE)
if(length(json_lines)!=19407L) stop(sprintf("Expected 19,407 JSONL records, found %d",length(json_lines)))
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

summary <- list(
  records=nrow(x),
  model="gpt-5.6-luna",
  reasoning="low",
  prompt_sha256="ce20acddf42e494a799d08b130d3e1bace95746035a7ad8e625fc8046a1bd07a",
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
