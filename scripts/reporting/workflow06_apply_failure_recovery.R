#!/usr/bin/env Rscript
suppressPackageStartupMessages({
  library(readr)
  library(dplyr)
  library(jsonlite)
  library(digest)
})

args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag, default=NULL){
  i <- match(flag,args)
  if(is.na(i)) return(default)
  if(i==length(args)) stop(sprintf("Missing value after %s",flag),call.=FALSE)
  args[[i+1L]]
}

baseline <- arg("--baseline")
recovery4 <- arg("--recovery4")
recovery1 <- arg("--recovery1")
out_dir <- arg("--output-dir","outputs/workflow06_corrected")
if(any(vapply(list(baseline,recovery4,recovery1),is.null,logical(1)))) stop("Missing required inputs",call.=FALSE)
dir.create(out_dir,recursive=TRUE,showWarnings=FALSE)

x <- read_csv(baseline,show_col_types=FALSE)
r4 <- read_csv(recovery4,show_col_types=FALSE)
r1 <- read_csv(recovery1,show_col_types=FALSE)

# Keep the three clean NONE recoveries from the first run, excluding the invalid pseudo-country record.
r4 <- r4 |> filter(record_id != "work-e8046bb0876a1942", !llm_failed)
r1 <- r1 |> filter(record_id == "work-e8046bb0876a1942", !llm_failed)

stopifnot(nrow(r4)==3L,nrow(r1)==1L)
repl <- bind_rows(r4,r1)
stopifnot(nrow(repl)==4L,!anyDuplicated(repl$record_id),all(repl$geography_status=="NONE"),all(repl$evidence_all_grounded),!any(repl$llm_failed))

cols <- intersect(names(repl), names(x))
for(i in seq_len(nrow(repl))){
  id <- repl$record_id[[i]]
  j <- which(x$record_id == id)
  stopifnot(length(j)==1L)
  for(nm in cols) x[[nm]][j] <- repl[[nm]][[i]]
  x$det_iso3c[j] <- trimws(ifelse(is.na(x$deterministic_primary_iso3c[j]),"",x$deterministic_primary_iso3c[j]))
  x$exact_agreement[j] <- x$det_iso3c[j] == ""
  x$deterministic_none[j] <- x$det_iso3c[j] == ""
  x$luna_none[j] <- TRUE
  x$discrepancy_type[j] <- if(x$exact_agreement[j]) "exact_agreement" else "deterministic_only_geography"
}

stopifnot(
  nrow(x)==19407L,
  !anyDuplicated(x$record_id),
  sum(x$geography_status=="RESOLVED")==7770L,
  sum(x$geography_status=="NONE")==11166L,
  sum(x$geography_status=="UNRESOLVED")==471L,
  sum(x$llm_failed)==0L,
  sum(!x$evidence_all_grounded)==235L
)

write_csv(x,file.path(out_dir,"geography_semantic_final.csv"),na="")
write_csv(x |> filter(geography_status=="UNRESOLVED"),file.path(out_dir,"geography_unresolved.csv"),na="")
write_csv(x |> filter(!evidence_all_grounded),file.path(out_dir,"geography_ungrounded_evidence.csv"),na="")
write_csv(x |> filter(llm_failed),file.path(out_dir,"geography_llm_failures.csv"),na="")
write_csv(x |> filter(discrepancy_type!="exact_agreement"),file.path(out_dir,"geography_deterministic_qc_discrepancies.csv"),na="")
write_csv(x |> count(discrepancy_type,name="n") |> mutate(pct=100*n/nrow(x)) |> arrange(desc(n)),
          file.path(out_dir,"discrepancy_patterns.csv"),na="")
write_csv(x |> count(geography_status,name="n") |> mutate(pct=100*n/nrow(x)),
          file.path(out_dir,"geography_status_counts.csv"),na="")

summary <- list(
  records=nrow(x),
  model="gpt-5.6-luna",
  reasoning="low",
  prompt_sha256="ce20acddf42e494a799d08b130d3e1bace95746035a7ad8e625fc8046a1bd07a",
  resolved_n=sum(x$geography_status=="RESOLVED"),
  none_n=sum(x$geography_status=="NONE"),
  unresolved_n=sum(x$geography_status=="UNRESOLVED"),
  evidence_not_grounded_n=sum(!x$evidence_all_grounded),
  llm_failures_n=sum(x$llm_failed),
  exact_agreement_discrepancy_class_n=sum(x$discrepancy_type=="exact_agreement"),
  qc_discrepancies_n=sum(x$discrepancy_type!="exact_agreement"),
  corrected_from_run="36265092530",
  failure_recovery_runs=c("36271055010","36271186232")
)
write_json(summary,file.path(out_dir,"workflow06_validated_summary.json"),auto_unbox=TRUE,pretty=TRUE)
cat(toJSON(summary,auto_unbox=TRUE,pretty=TRUE),"\n")
