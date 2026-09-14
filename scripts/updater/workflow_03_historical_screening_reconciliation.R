#!/usr/bin/env Rscript
suppressPackageStartupMessages(library(jsonlite))

args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag, default=NULL) {
  i <- match(flag,args)
  if (is.na(i)) return(default)
  if (i == length(args)) stop(sprintf("Missing value after %s",flag))
  args[[i+1L]]
}
input_path <- arg("--input")
base_history_path <- arg("--base-history")
patch_path <- arg("--patch")
output_dir <- arg("--output-dir","outputs/fresh_workflow03")
if (is.null(input_path) || is.null(base_history_path) || is.null(patch_path)) {
  stop("--input, --base-history and --patch are required")
}
dir.create(output_dir,recursive=TRUE,showWarnings=FALSE)

`%||%` <- function(x,y) if (is.null(x)) y else x
now_utc <- function() format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ")

read_jsonl <- function(path) {
  x <- readLines(path,warn=FALSE,encoding="UTF-8")
  x <- x[nzchar(trimws(x))]
  lapply(seq_along(x), function(i) {
    tryCatch(fromJSON(x[[i]],simplifyVector=FALSE),
             error=function(e) stop(sprintf("Invalid JSONL %s line %d: %s",path,i,conditionMessage(e))))
  })
}
write_jsonl <- function(rows,path) {
  con <- file(path,"wt",encoding="UTF-8"); on.exit(close(con))
  for (x in rows) writeLines(toJSON(x,auto_unbox=TRUE,null="null",na="null",digits=NA),con)
}
lens_id <- function(r) as.character(r$identity$lens_id %||% r$canonical$lens_id %||% "")
dedup_status <- function(r) as.character(r$deduplication$status %||% "")
duplicate_members <- function(r) {
  x <- r$deduplication$duplicate_members %||% list()
  if (is.null(x)) character() else as.character(unlist(x,use.names=FALSE))
}

records <- read_jsonl(input_path)
ids <- vapply(records,lens_id,character(1))
if (any(!nzchar(ids)) || anyDuplicated(ids)) stop("Fresh canonical Lens-ID invariant failed")
if (any(vapply(records,function(r)is.null(r$deduplication$status),logical(1)))) stop("Workflow 03 requires Workflow 02 deduplication state")

base <- read_jsonl(base_history_path)
patch <- read_jsonl(patch_path)

derive_decision <- function(x) {
  d <- tolower(as.character(x$screening_decision %||% ""))
  if (d %in% c("include","exclude")) return(d)
  h <- x$proposed_screening_history %||% list()
  ds <- unique(Filter(function(z) z %in% c("include","exclude"),
                      vapply(h,function(y)tolower(as.character(y$decision %||% "")),character(1))))
  if (length(ds)==1L) ds[[1]] else NA_character_
}

decision_map <- list()
provenance_map <- list()
unresolved_base <- character()
for (x in base) {
  id <- as.character(x$canonical_lens_id %||% "")
  if (!nzchar(id)) next
  d <- derive_decision(x)
  if (is.na(d)) {
    unresolved_base <- c(unresolved_base,id)
  } else {
    decision_map[[id]] <- d
    provenance_map[[id]] <- list(source="base_reconciliation_artifact", history=x$proposed_screening_history %||% list())
  }
}
for (x in patch) {
  id <- as.character(x$canonical_lens_id %||% "")
  d <- tolower(as.character(x$screening_decision %||% ""))
  if (!nzchar(id) || !(d %in% c("include","exclude"))) stop("Invalid Workflow 03 patch row")
  decision_map[[id]] <- d
  provenance_map[[id]] <- list(source="adjudication_patch", reason=x$reason %||% NULL)
}

ledger_ids <- names(decision_map)
ledger_decisions <- vapply(decision_map,identity,character(1))
if (length(ledger_ids) != 17849L) stop(sprintf("Historical decision ledger count mismatch: %d != 17849",length(ledger_ids)))
if (sum(ledger_decisions=="include") != 12805L || sum(ledger_decisions=="exclude") != 5044L) {
  stop("Historical decision ledger INCLUDE/EXCLUDE totals do not match adjudicated checkpoint")
}

normalized <- lapply(sort(ledger_ids), function(id) list(
  canonical_lens_id=id,
  screening_decision=decision_map[[id]],
  provenance=provenance_map[[id]]
))
write_jsonl(normalized,file.path(output_dir,"historical_screening_decisions_normalized.jsonl"))

present <- intersect(ledger_ids,ids)
absent <- setdiff(ledger_ids,ids)
writeLines(absent,file.path(output_dir,"historical_decision_ids_absent_from_fresh_records.txt"))

id_to_index <- setNames(seq_along(ids),ids)
conflicts <- list()
representative_summary <- list()
counts <- c(include=0L,exclude=0L,not_previously_screened=0L,conflict=0L)
source_decision_ids_used <- character()

for (i in seq_along(records)) {
  r <- records[[i]]
  st <- dedup_status(r)
  id <- ids[[i]]
  if (st == "duplicate") {
    direct <- decision_map[[id]]
    r$screening <- list(
      workflow="03_historical_screening_reconciliation",
      implementation_language="R",
      status="duplicate_manifestation",
      direct_historical_decision=if(is.null(direct)) NULL else direct,
      decision_applied_to=r$deduplication$duplicate_of %||% NULL,
      downstream_eligible=FALSE
    )
    records[[i]] <- r
    next
  }
  if (!(st %in% c("unique","canonical"))) stop(sprintf("Unexpected deduplication status %s",st))
  group_ids <- unique(c(id,duplicate_members(r)))
  ds <- Filter(function(x)!is.null(x), lapply(group_ids,function(g) decision_map[[g]]))
  src_ids <- group_ids[vapply(group_ids,function(g)!is.null(decision_map[[g]]),logical(1))]
  uniq <- unique(unlist(ds,use.names=FALSE))
  if (length(uniq)==0L) {
    counts["not_previously_screened"] <- counts["not_previously_screened"] + 1L
    r$screening <- list(
      workflow="03_historical_screening_reconciliation",
      implementation_language="R",
      status="not_previously_screened",
      decision=NULL,
      requires_screening=TRUE,
      downstream_eligible=FALSE
    )
  } else if (length(uniq)==1L) {
    d <- uniq[[1]]
    counts[d] <- counts[d] + 1L
    source_decision_ids_used <- c(source_decision_ids_used,src_ids)
    r$screening <- list(
      workflow="03_historical_screening_reconciliation",
      implementation_language="R",
      status="historical_decision_applied",
      decision=d,
      source_lens_ids=src_ids,
      propagated_across_deduplication_group=length(group_ids)>1L,
      requires_screening=FALSE,
      downstream_eligible=identical(d,"include")
    )
  } else {
    counts["conflict"] <- counts["conflict"] + 1L
    cobj <- list(
      representative_lens_id=id,
      group_lens_ids=group_ids,
      historical_decisions=lapply(src_ids,function(g)list(lens_id=g,decision=decision_map[[g]]))
    )
    conflicts[[length(conflicts)+1L]] <- cobj
    r$screening <- list(
      workflow="03_historical_screening_reconciliation",
      implementation_language="R",
      status="historical_decision_conflict",
      decision=NULL,
      requires_screening=FALSE,
      downstream_eligible=FALSE,
      conflict=cobj$historical_decisions
    )
  }
  representative_summary[[length(representative_summary)+1L]] <- list(
    lens_id=id,deduplication_status=st,screening_status=r$screening$status,
    screening_decision=r$screening$decision %||% NULL,
    source_lens_ids=r$screening$source_lens_ids %||% list()
  )
  records[[i]] <- r
}

write_jsonl(records,file.path(output_dir,"annotated_records.jsonl"))
write_jsonl(conflicts,file.path(output_dir,"historical_decision_conflicts.jsonl"))
write_jsonl(representative_summary,file.path(output_dir,"representative_screening_audit.jsonl"))

rep_n <- sum(vapply(records,function(r)dedup_status(r)%in%c("unique","canonical"),logical(1)))
summary <- list(
  input_records=length(records),
  output_records=length(records),
  downstream_representatives=rep_n,
  historical_decision_ledger_records=length(ledger_ids),
  historical_decision_ids_present_in_fresh_records=length(present),
  historical_decision_ids_absent_from_fresh_records=length(absent),
  representatives_include=unname(counts["include"]),
  representatives_exclude=unname(counts["exclude"]),
  representatives_not_previously_screened=unname(counts["not_previously_screened"]),
  representatives_with_historical_conflict=unname(counts["conflict"]),
  source_historical_decision_ids_used=length(unique(source_decision_ids_used)),
  unresolved_base_history_ids_after_patch=length(setdiff(unresolved_base,names(decision_map))),
  implementation_language="R"
)
if (summary$output_records != summary$input_records) stop("Workflow 03 cardinality invariant failed")
if (summary$representatives_include + summary$representatives_exclude +
    summary$representatives_not_previously_screened + summary$representatives_with_historical_conflict != rep_n) {
  stop("Workflow 03 representative status count invariant failed")
}
writeLines(toJSON(summary,auto_unbox=TRUE,pretty=TRUE,null="null"),
           file.path(output_dir,"historical_screening_summary.json"))
writeLines(toJSON(list(workflow="workflow_03_historical_screening_reconciliation",created_at=now_utc(),summary=summary),
                  auto_unbox=TRUE,pretty=TRUE,null="null"),
           file.path(output_dir,"historical_screening_audit.json"))
message(toJSON(summary,auto_unbox=TRUE,pretty=TRUE))
if (length(conflicts)>0L) {
  message(sprintf("AUDIT REQUIRES REVIEW: %d deduplication groups contain conflicting historical decisions.",length(conflicts)))
} else {
  message("PASS: Workflow 03 historical screening reconciliation complete; no historical decision conflicts.")
}
