#!/usr/bin/env Rscript
suppressPackageStartupMessages({
  library(readr)
  library(dplyr)
  library(jsonlite)
  library(digest)
})

args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag, default=NULL) {
  i <- match(flag,args)
  if(is.na(i)) return(default)
  if(i==length(args)) stop(sprintf("Missing value after %s",flag),call.=FALSE)
  args[[i+1L]]
}

w05_path <- arg("--w05")
w06_path <- arg("--w06")
w06_recovery1_path <- arg("--w06-recovery1")
w06_recovery2_path <- arg("--w06-recovery2")
w06_grounding_residual_path <- arg("--w06-grounding-residual")
w07_review_path <- arg("--w07-review")
w07_scores_path <- arg("--w07-scores")
w07_late_exclusions_path <- arg("--w07-late-exclusions")
existing_geo_decisions_path <- arg("--existing-geography-decisions")
out_dir <- arg("--output-dir","outputs/workflow08_intake")

req_files <- c(w05_path,w06_path,w06_recovery1_path,w06_recovery2_path,
               w06_grounding_residual_path,w07_review_path,w07_scores_path,
               w07_late_exclusions_path,existing_geo_decisions_path)
if(any(vapply(req_files,function(x)is.null(x)||!file.exists(x),logical(1)))) {
  stop("All W05-W07 input and existing-decision files are required",call.=FALSE)
}
dir.create(out_dir,recursive=TRUE,showWarnings=FALSE)

clean_chr <- function(x) {
  x <- as.character(x)
  x[is.na(x)] <- ""
  x
}
is_true <- function(x) toupper(clean_chr(x))=="TRUE"

w05 <- read_csv(w05_path,show_col_types=FALSE,progress=FALSE)
w06 <- read_csv(w06_path,show_col_types=FALSE,progress=FALSE)
r1 <- read_csv(w06_recovery1_path,show_col_types=FALSE,progress=FALSE)
r2 <- read_csv(w06_recovery2_path,show_col_types=FALSE,progress=FALSE)
g_resid <- read_csv(w06_grounding_residual_path,show_col_types=FALSE,progress=FALSE)
w07q <- read_csv(w07_review_path,show_col_types=FALSE,progress=FALSE)
w07s <- read_csv(w07_scores_path,show_col_types=FALSE,progress=FALSE)
w07x <- read_csv(w07_late_exclusions_path,show_col_types=FALSE,progress=FALSE)

stopifnot(nrow(w05)==19407L,!anyDuplicated(w05$record_id))
stopifnot(nrow(w06)==19407L,!anyDuplicated(w06$record_id))
stopifnot(nrow(w07q)==121L,!anyDuplicated(w07q$record_id))
stopifnot(nrow(w07x)==123L,!anyDuplicated(w07x$record_id))

# Apply the two validated W06 technical recovery layers in chronological order.
recovery_cols <- intersect(
  c("geography_status","luna_iso3c","luna_country_names","luna_evidence",
    "luna_mapping_reason","evidence_all_grounded","geography_reason",
    "llm_failed","llm_error"),
  names(w06)
)
apply_recovery <- function(base,repl) {
  if(!nrow(repl)) return(base)
  idx <- match(repl$record_id,base$record_id)
  if(any(is.na(idx))) stop("W06 recovery contains record_id absent from W06 base")
  for(col in recovery_cols) {
    if(col %in% names(repl)) base[[col]][idx] <- repl[[col]]
  }
  base
}
w06 <- apply_recovery(w06,r1)
w06 <- apply_recovery(w06,r2)

if(sum(w06$geography_status=="UNRESOLVED",na.rm=TRUE)!=471L) {
  stop("Expected 471 W06 UNRESOLVED records after validated recovery")
}
if(sum(is_true(w06$llm_failed))!=0L) {
  stop("W06 still contains model failures after validated recovery")
}

geo_decisions <- lapply(
  readLines(existing_geo_decisions_path,warn=FALSE,encoding="UTF-8"),
  function(z) if(nzchar(trimws(z))) fromJSON(z,simplifyVector=FALSE) else NULL
)
geo_decisions <- Filter(Negate(is.null),geo_decisions)
pre_adjudicated_geo_ids <- unique(vapply(
  geo_decisions,
  function(x) as.character(x$record_id %||% ""),
  character(1)
))
`%||%` <- function(x,y) if(is.null(x)||length(x)==0) y else x

# Corpus context comes from the validated W05 handoff because it contains the
# exact 19,407 stable IDs with title/abstract and species state.
context <- w05 |>
  select(record_sequence,record_id,title,abstract,farmed_species_codes,farmed_species)

issue_map <- setNames(vector("list",nrow(context)),as.character(context$record_id))
add_issue <- function(record_id,issue) {
  rid <- as.character(record_id)
  if(!rid %in% names(issue_map)) stop("Issue record absent from W05 context: ",rid)
  issue_map[[rid]] <<- c(issue_map[[rid]],list(issue))
}

# W05: NONE is a review state, never a terminal final species value.
w05_none <- context |> filter(farmed_species_codes=="NONE")
if(nrow(w05_none)!=169L) stop("Expected 169 W05 species NONE records")
for(rid in w05_none$record_id) {
  add_issue(rid,list(
    source_workflow="05",
    issue_type="species_none",
    automated_value=list(
      farmed_species_codes="NONE",
      farmed_species="NONE"
    ),
    allowed_human_outcomes=c(
      "assign_named_species",
      "assign_unspecified_species",
      "exclude_record"
    )
  ))
}

# W06: minimum escalation only. Deterministic/Luna disagreement is QC, not a
# human-review trigger. Existing human geography decisions suppress a new W06
# issue for the same record.
w06_unresolved <- w06 |>
  filter(geography_status=="UNRESOLVED",!record_id %in% pre_adjudicated_geo_ids)
for(i in seq_len(nrow(w06_unresolved))) {
  z <- w06_unresolved[i,,drop=FALSE]
  add_issue(z$record_id,list(
    source_workflow="06",
    issue_type="geography_unresolved",
    automated_value=list(
      geography_status=clean_chr(z$geography_status),
      luna_iso3c=clean_chr(z$luna_iso3c),
      luna_country_names=clean_chr(z$luna_country_names),
      luna_evidence=clean_chr(z$luna_evidence),
      geography_reason=clean_chr(z$geography_reason)
    ),
    allowed_human_outcomes=c("assign_country_set","assign_none")
  ))
}

resid_ids <- unique(as.character(g_resid$record_id))
resid_ids <- resid_ids[!resid_ids %in% pre_adjudicated_geo_ids]
if(length(resid_ids)) {
  if(any(!resid_ids %in% w06$record_id)) stop("Residual grounding ID absent from W06")
  for(rid in resid_ids) {
    z <- w06[match(rid,w06$record_id),,drop=FALSE]
    add_issue(rid,list(
      source_workflow="06",
      issue_type="geography_evidence_unvalidated",
      automated_value=list(
        geography_status=clean_chr(z$geography_status),
        luna_iso3c=clean_chr(z$luna_iso3c),
        luna_country_names=clean_chr(z$luna_country_names),
        luna_evidence=clean_chr(z$luna_evidence),
        geography_reason=clean_chr(z$geography_reason)
      ),
      allowed_human_outcomes=c("accept_model","override_country_set","assign_none")
    ))
  }
}

# W07: preserve all topic-support evidence for disagreement cases and the
# targeted eligibility-rescreen state for zero-topic uncertain cases.
score_index <- split(seq_len(nrow(w07s)),as.character(w07s$record_id))
for(i in seq_len(nrow(w07q))) {
  q <- w07q[i,,drop=FALSE]
  rid <- as.character(q$record_id)
  reason <- as.character(q$workflow08_reason)
  if(reason=="extreme_three_pass_topic_disagreement") {
    idx <- score_index[[rid]]
    if(is.null(idx)||!length(idx)) stop("Topic disagreement record lacks pathway scores: ",rid)
    z <- w07s[idx,,drop=FALSE]
    pathways <- lapply(seq_len(nrow(z)),function(j) list(
      path_id=as.character(z$path_id[[j]]),
      hierarchy_path=as.character(z$hierarchy_path[[j]]),
      confidence_n=as.integer(z$confidence_n[[j]]),
      stars=as.character(z$stars[[j]]),
      role_a=clean_chr(z$role_a[[j]]),
      role_b=clean_chr(z$role_b[[j]]),
      role_c=clean_chr(z$role_c[[j]]),
      reason_a=clean_chr(z$reason_a[[j]]),
      reason_b=clean_chr(z$reason_b[[j]]),
      reason_c=clean_chr(z$reason_c[[j]]),
      retained_for_analysis=isTRUE(z$retained_for_analysis[[j]]),
      retention_basis=as.character(z$retention_basis[[j]])
    ))
    add_issue(rid,list(
      source_workflow="07",
      issue_type="topic_extreme_disagreement",
      automated_value=list(
        mean_pairwise_jaccard=as.numeric(q$mean_pairwise_jaccard),
        topic_count_raw=as.integer(q$topic_count_raw),
        topic_count_retained=as.integer(q$topic_count_retained),
        pathways=pathways
      ),
      allowed_human_outcomes=c("accept_retained_topics","replace_topic_set","exclude_record")
    ))
  } else if(reason=="zero_topic_eligibility_uncertain") {
    add_issue(rid,list(
      source_workflow="07",
      issue_type="zero_topic_eligibility_uncertain",
      automated_value=list(
        zero_topic=TRUE,
        zero_topic_rescreen_decision=as.character(q$zero_topic_rescreen_decision),
        screening_action=as.character(q$screening_action)
      ),
      allowed_human_outcomes=c("include_uncoded","exclude_record")
    ))
  } else {
    stop("Unexpected W07 Workflow 08 reason: ",reason)
  }
}

pending_ids <- names(issue_map)[lengths(issue_map)>0L]
pending_ids <- pending_ids[order(match(pending_ids,context$record_id))]

queue <- lapply(pending_ids,function(rid) {
  z <- context[match(rid,context$record_id),,drop=FALSE]
  list(
    record_id=rid,
    record_sequence=as.integer(z$record_sequence),
    title=clean_chr(z$title),
    abstract=clean_chr(z$abstract),
    issues=issue_map[[rid]]
  )
})

queue_path <- file.path(out_dir,"workflow08_review_queue.jsonl")
con <- file(queue_path,open="wb")
on.exit(close(con),add=TRUE)
for(x in queue) {
  writeLines(toJSON(x,auto_unbox=TRUE,null="null",na="null"),con=con,useBytes=TRUE)
}
close(con); on.exit(NULL,add=FALSE)

# Machine-readable issue-level table for QA and overlap accounting.
issue_rows <- bind_rows(lapply(pending_ids,function(rid) {
  bind_rows(lapply(issue_map[[rid]],function(q) data.frame(
    record_id=rid,
    source_workflow=as.character(q$source_workflow),
    issue_type=as.character(q$issue_type),
    stringsAsFactors=FALSE
  )))
}))
write_csv(issue_rows,file.path(out_dir,"workflow08_issue_index.csv"),na="")

# The 123 W07 late automatic exclusions are not human-review cases but are a
# required W08 final-assembly input.
write_csv(w07x,file.path(out_dir,"workflow08_late_automatic_exclusions.csv"),na="")

by_type <- issue_rows |> count(source_workflow,issue_type,name="issues") |> arrange(source_workflow,issue_type)
write_csv(by_type,file.path(out_dir,"workflow08_issue_counts.csv"),na="")

multi <- issue_rows |> count(record_id,name="n_issues") |> filter(n_issues>1L) |> arrange(desc(n_issues),record_id)
write_csv(multi,file.path(out_dir,"workflow08_multi_issue_records.csv"),na="")

manifest <- list(
  schema="living-evidence-map-workflow08-review-queue-v1",
  created_at_utc=format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ"),
  input_population=19407L,
  w04_pending_human_review=0L,
  w05_species_none=169L,
  w06_unresolved_after_recovery=nrow(w06_unresolved),
  w06_grounding_residual=length(resid_ids),
  w06_existing_human_geography_decisions=length(geo_decisions),
  w07_human_review=121L,
  w07_late_automatic_exclusions=123L,
  unique_records_pending_human_review=length(queue),
  records_with_multiple_pending_issues=nrow(multi),
  total_pending_issues=nrow(issue_rows),
  queue_sha256=digest(file=queue_path,algo="sha256",serialize=FALSE),
  issue_index_sha256=digest(file=file.path(out_dir,"workflow08_issue_index.csv"),algo="sha256",serialize=FALSE),
  source_runs=list(
    workflow05="36268840588",
    workflow06="36265092530",
    workflow06_failure_recovery_1="36271055010",
    workflow06_failure_recovery_2="36271186232",
    workflow07_finalisation="36305907080"
  ),
  source_archives=list(
    workflow05_zenodo="22982751",
    workflow06_zenodo="22983049"
  ),
  note="W04 has no unresolved current-baseline cases. W05 NONE, W06 minimum-escalation geography cases, and W07 final human-review cases are deduplicated by record_id. W07 late automatic exclusions are preserved separately for final assembly."
)
write_json(manifest,file.path(out_dir,"workflow08_review_queue_manifest.json"),
           pretty=TRUE,auto_unbox=TRUE,null="null")

writeLines("PASS",file.path(out_dir,"WORKFLOW08_INTAKE_PASS.ok"))
cat(toJSON(manifest,pretty=TRUE,auto_unbox=TRUE),"
")
