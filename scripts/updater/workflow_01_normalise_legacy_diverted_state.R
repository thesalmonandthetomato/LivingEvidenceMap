#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(data.table)
  library(jsonlite)
  library(digest)
})

args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag, default=NULL) {
  i <- match(flag,args)
  if (is.na(i)) return(default)
  if (i==length(args)) stop(sprintf("Missing value after %s",flag),call.=FALSE)
  args[[i+1L]]
}

combined_path <- arg("--combined-decisions")
recovered_path <- arg("--recovered-adjudications")
rule_path <- arg("--rule-decisions")
human_path <- arg("--human-decisions")
output_dir <- arg("--output-dir")
base_run_id <- arg("--base-run-id","35964195676")
recovery_run_id <- arg("--recovery-run-id","36049567027")
resolution_run_id <- arg("--resolution-run-id","36056439618")

if (any(vapply(list(combined_path,recovered_path,rule_path,human_path,output_dir),is.null,logical(1)))) {
  stop("Required: --combined-decisions --recovered-adjudications --rule-decisions --human-decisions --output-dir",call.=FALSE)
}
dir.create(output_dir,recursive=TRUE,showWarnings=FALSE)

read_jsonl <- function(path) {
  z <- readLines(path,warn=FALSE,encoding="UTF-8")
  z <- z[nzchar(trimws(z))]
  lapply(z,fromJSON,simplifyVector=FALSE)
}
write_jsonl <- function(xs,path) {
  con <- file(path,"wt",encoding="UTF-8")
  on.exit(close(con),add=TRUE)
  if(length(xs)) for(x in xs) {
    writeLines(toJSON(x,auto_unbox=TRUE,null="null",na="null",digits=NA),con,useBytes=TRUE)
  }
}

pairs <- fread(combined_path,na.strings=c("","NA"))
required <- c("pair_key","rescored_classification","rescored_rule","review_route")
if(length(setdiff(required,names(pairs)))) stop("Combined pair table lacks required state columns",call.=FALSE)
if(anyDuplicated(pairs$pair_key)) stop("Combined pair table contains duplicate pair_key values",call.=FALSE)
if(!("manual_review_needed" %in% names(pairs))) pairs[, manual_review_needed := review_route=="manual_review"]
setkey(pairs,pair_key)

legacy <- pairs[review_route=="workflow04_exclusion_candidate"]
if(nrow(legacy)!=3004L) stop(sprintf("Expected exactly 3004 legacy-diverted rows; found %d",nrow(legacy)),call.=FALSE)

legacy_review <- legacy[rescored_classification=="review"]
legacy_candidate <- legacy[rescored_classification=="unresolved" & rescored_rule=="candidate_only"]
if(nrow(legacy_review)!=730L) stop(sprintf("Expected 730 legacy review rows; found %d",nrow(legacy_review)),call.=FALSE)
if(nrow(legacy_candidate)!=2274L) stop(sprintf("Expected 2274 legacy candidate_only rows; found %d",nrow(legacy_candidate)),call.=FALSE)
if(nrow(legacy_review)+nrow(legacy_candidate)!=nrow(legacy)) stop("Legacy diverted state contains unexpected row classes",call.=FALSE)

recovered <- read_jsonl(recovered_path)
rules <- read_jsonl(rule_path)
humans <- read_jsonl(human_path)

if(length(recovered)!=730L) stop(sprintf("Expected 730 recovered adjudications; found %d",length(recovered)),call.=FALSE)
if(length(rules)!=258L) stop(sprintf("Expected 258 rule-resolved decisions; found %d",length(rules)),call.=FALSE)
if(length(humans)!=19L) stop(sprintf("Expected 19 explicit residual human decisions; found %d",length(humans)),call.=FALSE)

rec_ids <- vapply(recovered,function(x)as.character(x$review_case_id),character(1))
rec_keys <- vapply(recovered,function(x)as.character(x$pair_key),character(1))
rule_ids <- vapply(rules,function(x)as.character(x$review_case_id),character(1))
human_ids <- vapply(humans,function(x)as.character(x$review_case_id),character(1))
if(anyDuplicated(rec_ids)||anyDuplicated(rec_keys)||anyDuplicated(rule_ids)||anyDuplicated(human_ids)) {
  stop("Duplicate case ID or pair key in recovered decision inputs",call.=FALSE)
}
if(!setequal(rec_keys,legacy_review$pair_key)) stop("Recovered 730 pair keys do not exactly match the legacy review-class rows",call.=FALSE)

promotions <- vapply(recovered,function(x)as.character(x$promotion),character(1))
human_review_ids <- rec_ids[promotions=="human_review"]
if(length(human_review_ids)!=277L) stop("Recovered adjudications no longer contain exactly 277 human-review cases",call.=FALSE)
if(length(intersect(rule_ids,human_ids))) stop("Rule-resolved and explicit-human case IDs overlap",call.=FALSE)
if(!setequal(c(rule_ids,human_ids),human_review_ids)) stop("258 rule + 19 human decisions do not exactly cover the 277 recovered human-review cases",call.=FALSE)

rule_by_id <- setNames(rules,rule_ids)
human_by_id <- setNames(humans,human_ids)

decision_for <- function(x) {
  p <- as.character(x$promotion)
  id <- as.character(x$review_case_id)
  if(p %in% c("duplicate","not_duplicate")) {
    return(list(decision=p,source="recovered_llm"))
  }
  if(!identical(p,"human_review")) stop(sprintf("Unexpected recovered promotion for %s: %s",id,p),call.=FALSE)
  if(id %in% rule_ids) {
    d <- as.character(rule_by_id[[id]]$decision)
    if(!(d %in% c("duplicate","not_duplicate"))) stop(sprintf("Invalid rule decision for %s",id),call.=FALSE)
    return(list(decision=d,source="user_approved_title_class_rule"))
  }
  if(id %in% human_ids) {
    d <- as.character(human_by_id[[id]]$decision)
    if(!(d %in% c("duplicate","not_duplicate"))) stop(sprintf("Invalid human decision for %s",id),call.=FALSE)
    return(list(decision=d,source="explicit_user_human_adjudication"))
  }
  stop(sprintf("No final recovered decision for %s",id),call.=FALSE)
}

now <- format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ")
recovered_audit <- vector("list",length(recovered))
final_recovered <- character(length(recovered))
source_recovered <- character(length(recovered))

for(i in seq_along(recovered)) {
  x <- recovered[[i]]
  key <- as.character(x$pair_key)
  d <- decision_for(x)
  before <- pairs[.(key),.(rescored_classification,rescored_rule,review_route,manual_review_needed)]
  if(nrow(before)!=1L) stop(sprintf("Recovered pair missing or non-unique in combined state: %s",key),call.=FALSE)

  new_rule <- switch(
    d$source,
    recovered_llm="workflow01_recovered_llm_adjudication",
    user_approved_title_class_rule="workflow01_recovered_title_rule_adjudication",
    explicit_user_human_adjudication="workflow01_recovered_human_adjudication",
    stop("Unknown recovered decision source",call.=FALSE)
  )
  new_route <- if(identical(d$decision,"duplicate")) "automatic_duplicate" else "non_duplicate"

  pairs[.(key), `:=`(
    rescored_classification=d$decision,
    rescored_rule=new_rule,
    review_route=new_route,
    manual_review_needed=FALSE
  )]

  final_recovered[[i]] <- d$decision
  source_recovered[[i]] <- d$source
  recovered_audit[[i]] <- list(
    schema="living-evidence-map-workflow01-recovered-decision-application-v1",
    review_case_id=as.character(x$review_case_id),
    pair_key=key,
    before=list(
      rescored_classification=as.character(before$rescored_classification),
      rescored_rule=as.character(before$rescored_rule),
      review_route=as.character(before$review_route),
      manual_review_needed=as.logical(before$manual_review_needed)
    ),
    after=list(
      rescored_classification=d$decision,
      rescored_rule=new_rule,
      review_route=new_route,
      manual_review_needed=FALSE
    ),
    decision_source=d$source,
    model_decision=if(is.null(x$model_decision)) NULL else x$model_decision,
    model_confidence=if(is.null(x$model_confidence)) NULL else x$model_confidence,
    base_dedup_run_id=base_run_id,
    recovery_run_id=recovery_run_id,
    resolution_run_id=resolution_run_id,
    applied_at_utc=now
  )
}

# candidate_only was a broad candidate-generation state, not a request for
# adjudication. Under the cleaned Workflow 01 routing rule, any pair that is
# neither duplicate nor review is a non-duplicate/no-review route. Preserve
# classifier evidence and change only the obsolete route state.
candidate_keys <- legacy_candidate$pair_key
clean_routes <- ifelse(
  legacy_candidate$rescored_classification=="duplicate","automatic_duplicate",
  ifelse(legacy_candidate$rescored_classification=="review","manual_review","non_duplicate")
)
if(length(clean_routes)!=2274L || !all(clean_routes=="non_duplicate")) {
  stop("Current deterministic routing rule does not map all 2274 candidate_only rows to non_duplicate",call.=FALSE)
}

candidate_audit <- vector("list",length(candidate_keys))
for(i in seq_along(candidate_keys)) {
  key <- candidate_keys[[i]]
  before <- pairs[.(key),.(rescored_classification,rescored_rule,review_route,manual_review_needed)]
  pairs[.(key), `:=`(review_route="non_duplicate",manual_review_needed=FALSE)]
  candidate_audit[[i]] <- list(
    schema="living-evidence-map-workflow01-legacy-route-migration-v1",
    pair_key=key,
    classifier_state=list(
      rescored_classification=as.character(before$rescored_classification),
      rescored_rule=as.character(before$rescored_rule)
    ),
    route_before=as.character(before$review_route),
    route_after="non_duplicate",
    manual_review_needed_before=as.logical(before$manual_review_needed),
    manual_review_needed_after=FALSE,
    migration_reason="legacy_workflow04_exclusion_candidate_route_removed_candidate_only_is_no_review_state",
    deterministic_rule="duplicate->automatic_duplicate; review->manual_review; otherwise->non_duplicate",
    base_dedup_run_id=base_run_id,
    migrated_at_utc=now
  )
}

if(any(pairs$review_route=="workflow04_exclusion_candidate")) stop("Legacy workflow04 exclusion route remains after migration",call.=FALSE)
if(any(pairs[.(candidate_keys),review_route]!="non_duplicate")) stop("Candidate-only route migration did not persist",call.=FALSE)
if(any(pairs[.(candidate_keys),manual_review_needed])) stop("Candidate-only rows still require manual review",call.=FALSE)
if(any(pairs[.(rec_keys),review_route]=="manual_review")) stop("Recovered 730 contains unresolved manual-review routes after application",call.=FALSE)

out_csv <- file.path(output_dir,"combined_pair_decisions.normalised.csv")
rec_audit_path <- file.path(output_dir,"recovered_730_application_audit.jsonl")
candidate_audit_path <- file.path(output_dir,"candidate_only_route_migration_audit.jsonl")
summary_path <- file.path(output_dir,"legacy_state_normalisation_summary.json")

fwrite(pairs,out_csv)
write_jsonl(recovered_audit,rec_audit_path)
write_jsonl(candidate_audit,candidate_audit_path)

summary <- list(
  schema="living-evidence-map-workflow01-legacy-state-normalisation-v1",
  status="complete",
  base_dedup_run_id=base_run_id,
  recovery_run_id=recovery_run_id,
  resolution_run_id=resolution_run_id,
  legacy_diverted_rows=3004L,
  recovered_review_rows=730L,
  recovered_final_decisions=as.list(table(final_recovered)),
  recovered_decision_sources=as.list(table(source_recovered)),
  candidate_only_rows=2274L,
  candidate_only_classifier_state_preserved=TRUE,
  candidate_only_route_after="non_duplicate",
  candidate_only_manual_review_after=FALSE,
  legacy_routes_remaining=sum(pairs$review_route=="workflow04_exclusion_candidate"),
  unresolved_manual_review_from_recovered_legacy_rows=0L,
  input_combined_sha256=digest(file=combined_path,algo="sha256",serialize=FALSE),
  recovered_adjudications_sha256=digest(file=recovered_path,algo="sha256",serialize=FALSE),
  rule_decisions_sha256=digest(file=rule_path,algo="sha256",serialize=FALSE),
  human_decisions_sha256=digest(file=human_path,algo="sha256",serialize=FALSE),
  output_combined_sha256=digest(file=out_csv,algo="sha256",serialize=FALSE),
  recovered_audit_sha256=digest(file=rec_audit_path,algo="sha256",serialize=FALSE),
  candidate_migration_audit_sha256=digest(file=candidate_audit_path,algo="sha256",serialize=FALSE),
  created_at_utc=now
)
writeLines(toJSON(summary,auto_unbox=TRUE,pretty=TRUE,null="null",na="null"),summary_path,useBytes=TRUE)

cat(sprintf(
  "PASS: normalised 3004 legacy-diverted rows: 730 recovered decisions applied + 2274 candidate_only routes migrated to non_duplicate; 0 legacy routes remain\n"
))
cat("Recovered decisions:",paste(names(table(final_recovered)),as.integer(table(final_recovered)),sep="=",collapse="; "), "\n")
cat("Decision sources:",paste(names(table(source_recovered)),as.integer(table(source_recovered)),sep="=",collapse="; "), "\n")
