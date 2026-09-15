#!/usr/bin/env Rscript
suppressPackageStartupMessages({
  library(jsonlite)
  library(digest)
})

args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag, default=NULL) {
  i <- match(flag,args)
  if (is.na(i)) return(default)
  if (i == length(args)) stop(sprintf("Missing value after %s",flag))
  args[[i+1L]]
}
input_path <- arg("--input")
base_history_path <- arg("--base-history")
second_pass_path <- arg("--second-pass")
output_dir <- arg("--output-dir","outputs/oneoff_reapply_historical_screening")
if (is.null(input_path) || is.null(base_history_path) || is.null(second_pass_path)) {
  stop("--input, --base-history and --second-pass are required")
}
dir.create(output_dir,recursive=TRUE,showWarnings=FALSE)

`%||%` <- function(x,y) if (is.null(x)) y else x
now_utc <- function() format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ")

read_jsonl <- function(path) {
  x <- readLines(path,warn=FALSE,encoding="UTF-8")
  x <- x[nzchar(trimws(x))]
  lapply(seq_along(x), function(i) {
    tryCatch(
      fromJSON(x[[i]],simplifyVector=FALSE),
      error=function(e) stop(sprintf("Invalid JSONL %s line %d: %s",path,i,conditionMessage(e)))
    )
  })
}

write_jsonl <- function(rows,path) {
  con <- file(path,"wt",encoding="UTF-8")
  on.exit(close(con))
  for (x in rows) writeLines(
    toJSON(x,auto_unbox=TRUE,null="null",na="null",digits=NA),
    con
  )
}

lens_id <- function(r) as.character(r$identity$lens_id %||% r$canonical$lens_id %||% "")
dedup_status <- function(r) as.character(r$deduplication$status %||% "")
duplicate_members <- function(r) {
  x <- r$deduplication$duplicate_members %||% list()
  if (is.null(x)) character() else as.character(unlist(x,use.names=FALSE))
}
publication_status_eligible <- function(r) {
  n <- r$notices %||% NULL
  if (is.null(n)) return(TRUE)
  if (!is.null(n$record_downstream_eligible)) return(isTRUE(n$record_downstream_eligible))
  if (!is.null(n$downstream_eligible)) return(isTRUE(n$downstream_eligible))
  TRUE
}
sha_id <- function(x) digest(x,algo="sha256",serialize=FALSE)

records <- read_jsonl(input_path)
ids <- vapply(records,lens_id,character(1))
if (any(!nzchar(ids)) || anyDuplicated(ids)) stop("Fresh canonical Lens-ID invariant failed")
if (any(vapply(records,function(r)is.null(r$deduplication$status),logical(1)))) {
  stop("One-off historical screening requires Workflow 02 deduplication state")
}

# Targeted post-dedup repair discovered during historical-screening audit.
# Lens record 083-231-522-166-315 is a malformed hybrid: its title matches
# Sano 1972 paper III, while its abstract matches Sano & Yamazaki 1973 paper V.
# It had bridged two distinct publications into one transitive cluster.
manual_dedup_repair_ids <- c(
  "115-623-146-471-00X",
  "083-231-522-166-315",
  "148-538-962-380-852"
)
idx <- match(manual_dedup_repair_ids, ids)
if (anyNA(idx)) stop("Targeted Sano dedup repair records are missing from canonical input")
if (!identical(dedup_status(records[[idx[[1]]]]), "canonical") ||
    !all(vapply(records[idx[-1]], function(r) identical(dedup_status(r), "duplicate"), logical(1)))) {
  stop("Targeted Sano dedup repair precondition failed: cluster state changed unexpectedly")
}
for (j in seq_along(idx)) {
  i <- idx[[j]]
  r <- records[[i]]
  r$deduplication$status <- "unique"
  r$deduplication$duplicate_of <- NULL
  r$deduplication$duplicate_members <- list()
  r$deduplication$downstream_eligible <- TRUE
  r$deduplication$manual_post_dedup_repair <- list(
    adjudicated_at=now_utc(),
    reason="split_malformed_hybrid_transitive_cluster",
    prior_representative="115-623-146-471-00X",
    evidence="J-STAGE confirms paper III (1972, DOI 10.2331/suisan.38.313) and paper V (1973, DOI 10.2331/suisan.39.477) are distinct publications; Lens record 083-231-522-166-315 combines title metadata from III with abstract metadata from V."
  )
  records[[i]] <- r
}

base <- read_jsonl(base_history_path)
second_pass <- read_jsonl(second_pass_path)

manual_override_hashes <- c(
"2a0dd7f883535a057d648cca1d6fb8aced5463290fea1cae9da8874f6c74eede"="exclude",
"a258e1ed509e9014e0a3b88abd61cdc937a5a118e945b9eb532a7e3e54dff1ea"="include",
"ef518a4e497bf2b59f36ee5e7796a120520e755257416fb580d819bf051e5ac5"="include",
"79aea41d2e90e5787ca34c623827188bf197a748c6a5daffa6d560fe37ebf751"="exclude",
"dc5e20aa461ace85626aeedcbc11704deec8e69c4c08f0efb4a0aea5e1c9a181"="include",
"065567c91c20345cc90ae19252970f575c77de8de6984b460ae70409aa2bb917"="include",
"b0c8e98bbeaf5f51a56f7c9566ef3675cdf64277c592524526b6fd6fa8027e5e"="exclude",
"d2f0078c8dcd672fc6f3b05a77d75385db155120d79da36b85463e3ccf371bb4"="include",
"3026b8fb1fe935495162803165f9143a00eae585fa9da76dfe24f2adac40d81f"="include",
"96ffd0a03a66f932f183e2b1a2e82d5e7f0aa4ea701db08716875991822dc49a"="include",
"cc8beb0f3cd8decae64f473ad36aea4acaa6d7085751b6afec7888ccf7b8d4a0"="exclude",
"cd67d855cbf1252406ecf82508b7445fb988630daaa89a593c926eabb88ad87c"="exclude",
"c93f4e6845c43354970e0a8971e9b10a8240669c5ff4ebeeb1d8da9db83d0d7c"="exclude",
"2717fc82feb899bff07f4487659072ef80bbad15de92a7b72157383798c6a14e"="include",
"c81a94cef944fa983e17dfcc1a2d231809b4046c59b32589041717eae045f0e6"="exclude",
"3ea1436e33daa01ca76a30901dbf33aa2c4a4ab38ebb530c01ea8044f390c048"="include",
"f9bad56bfd5ca22352e1f45752c5abf60eaa46a665f0f1609846ce61bec57ced"="include",
"f8c980b9f0b06ee5c1ae8438c7927b2dc0cee3821f683da70a61a64cbec1655e"="include",
"01ec9966b322100b42fabd22521d6c793ea2688e7adfd39a25e05affda26e91d"="exclude",
"de2430bce2c1291453792b058bef60aedb8a81f34557fd3811b615a331a0b7a0"="include",
"9b9eaa5af34c1f38b859a67ad9306b68c8b3a3eff58f95b0042c045ed503cc65"="include",
"4bedf208fc25ae1e23ff192ec9bb2b81da89a64d4dbe07b33250346e23c0241b"="include",
"d5bfaa72a6ea3dd21e6c60fe37f66e64a5587118572d3ef25c7f40a678e45683"="include",
"67298704231630a38050bf94cf0f1b74fa17a69ba2eeea67467e938f1dc03f83"="include",
"c5c5ccd4efcd430261dc59a367462a0afa573cc54686d841f7a72cf035461491"="include",
"e08f33118d3371aaa9787748dfcc5d1310cdd5c8f36f5700d31b3985ccf39c67"="include",
"c91e4726c19bee7603da98403fca1d2fa83daa96eee563b63ba318276cad84c4"="include",
"7fa2115622e4ef4a891b1fd813cc62b1ef5a1558bbc237f6488bb396aff6b8fc"="exclude",
"8650e77b8bf60429738e92e815e4da175320d5e81987ac621c3fb99f13747134"="include",
"f687227e2d7fafd8958c1a67e0e13ea8f507c921d44bb51d89fef5f4687102bb"="include",
"6660a000871f25b220628e816921916b41c3a0d773e9de27ca4b2e386fce854d"="exclude",
"257bd4879ccebd618b764b67c9f9ea6a7960d090fd93523dc1c773073cd0f698"="exclude",
"900fab6c4ab633b930d2e2a7344b798be8f0d4898572913b2ced4ee294ed8645"="include",
"791010225f89d8791d9d0e9a0354c7622ce1e310fd91637fa5dd944215db85d7"="include",
"15c0dcbd37df36efbd0526c23eb7d20744594ce9b896e2e9da78c9101dc33ac5"="include",
"94cff4ca7f44752bb06366762f08ade80dbbb17209436922388c3834280c5eb1"="exclude",
"42d87c04f549f9043daca8d2a28dc6e3fae916ce183536827c1621b1182e2173"="include"
)

derive_decision <- function(x) {
  d <- tolower(as.character(x$screening_decision %||% ""))
  if (d %in% c("include","exclude")) return(d)
  h <- x$proposed_screening_history %||% list()
  ds <- unique(Filter(
    function(z) z %in% c("include","exclude"),
    vapply(h,function(y)tolower(as.character(y$decision %||% "")),character(1))
  ))
  if (length(ds)==1L) ds[[1]] else NA_character_
}

decision_map <- list()
provenance_map <- list()
base_ids <- character()

for (x in base) {
  id <- as.character(x$canonical_lens_id %||% "")
  if (!nzchar(id)) next
  base_ids <- c(base_ids,id)
  d <- derive_decision(x)
  if (!is.na(d)) {
    decision_map[[id]] <- d
    provenance_map[[id]] <- list(source="base_reconciliation_artifact")
  }
}

for (x in second_pass) {
  if (isTRUE(x$candidate_already_decisioned_first_pass)) next
  id <- as.character(x$candidate_lens_ids %||% "")
  d <- tolower(as.character(x$decision %||% ""))
  if (!nzchar(id) || !(d %in% c("include","exclude"))) stop("Invalid second-pass row")
  decision_map[[id]] <- d
  provenance_map[[id]] <- list(
    source="second_pass_recovery_artifact",
    match_method=x$match_method %||% NULL
  )
}

candidate_ids <- unique(c(base_ids,names(decision_map),ids))
matched_manual <- 0L

for (id in candidate_ids) {
  h <- sha_id(id)
  if (h %in% names(manual_override_hashes)) {
    decision_map[[id]] <- unname(manual_override_hashes[[h]])
    provenance_map[[id]] <- list(
      source="manual_adjudication_2026-09-11",
      decision_key_sha256=h
    )
    matched_manual <- matched_manual + 1L
  }
}

if (matched_manual != length(manual_override_hashes)) {
  stop(sprintf(
    "Manual adjudication key recovery mismatch: %d/%d",
    matched_manual,
    length(manual_override_hashes)
  ))
}

ledger_ids <- names(decision_map)
ledger_decisions <- vapply(decision_map,identity,character(1))

if (length(ledger_ids) != 17849L) {
  stop(sprintf("Historical decision ledger count mismatch: %d != 17849",length(ledger_ids)))
}
if (sum(ledger_decisions=="include") != 12805L ||
    sum(ledger_decisions=="exclude") != 5044L) {
  stop("Historical decision totals do not match adjudicated checkpoint")
}

normalized <- lapply(sort(ledger_ids), function(id) list(
  canonical_lens_id=id,
  screening_decision=decision_map[[id]],
  provenance=provenance_map[[id]]
))
write_jsonl(
  normalized,
  file.path(output_dir,"historical_screening_decisions_normalized.jsonl")
)

present <- intersect(ledger_ids,ids)
absent <- setdiff(ledger_ids,ids)
writeLines(
  absent,
  file.path(output_dir,"historical_decision_ids_absent_from_fresh_records.txt")
)

historical_conflict_overrides <- list(
  "073-514-199-866-043"=list(
    decision="include",
    rationale="Journal final and PeerJ preprint manifestations are the same underlying study; retain the historical include attached to the final publication."
  ),
  "103-905-489-817-973"=list(
    decision="include",
    rationale="The canonical Aquaculture article is the final publication of the same survey represented by the alternate conference/proceedings manifestation; retain the historical include attached to the final publication."
  )
)

conflicts <- list()
representative_summary <- list()
new_queue <- list()
counts <- c(include=0L,exclude=0L,not_previously_screened=0L,publication_blocked_unscreened=0L,conflict=0L)
source_decision_ids_used <- character()

for (i in seq_along(records)) {
  r <- records[[i]]
  st <- dedup_status(r)
  id <- ids[[i]]
  publication_ok <- publication_status_eligible(r)

  if (st == "duplicate") {
    direct <- decision_map[[id]]
    r$screening <- list(
      workflow="04_historical_screening_reconciliation",
      implementation_language="R",
      status="duplicate_manifestation",
      direct_historical_decision=if(is.null(direct)) NULL else direct,
      decision_applied_to=r$deduplication$duplicate_of %||% NULL,
      publication_status_eligible=publication_ok,
      downstream_eligible=FALSE
    )
    records[[i]] <- r
    next
  }

  if (!(st %in% c("unique","canonical"))) {
    stop(sprintf("Unexpected deduplication status %s",st))
  }

  group_ids <- unique(c(id,duplicate_members(r)))
  src_ids <- group_ids[
    vapply(group_ids,function(g)!is.null(decision_map[[g]]),logical(1))
  ]
  uniq <- unique(vapply(src_ids,function(g)decision_map[[g]],character(1)))

  if (length(uniq)==0L) {
    if (publication_ok) {
      counts["not_previously_screened"] <- counts["not_previously_screened"] + 1L
      r$screening <- list(
        workflow="04_historical_screening_reconciliation",
        implementation_language="R",
        status="not_previously_screened",
        decision=NULL,
        requires_screening=TRUE,
        publication_status_eligible=TRUE,
        downstream_eligible=FALSE
      )
      new_queue[[length(new_queue)+1L]] <- r
    } else {
      counts["publication_blocked_unscreened"] <- counts["publication_blocked_unscreened"] + 1L
      r$screening <- list(
        workflow="04_historical_screening_reconciliation",
        implementation_language="R",
        status="not_previously_screened_publication_blocked",
        decision=NULL,
        requires_screening=FALSE,
        publication_status_eligible=FALSE,
        downstream_eligible=FALSE
      )
    }
  } else if (length(uniq)==1L) {
    d <- uniq[[1]]
    counts[d] <- counts[d] + 1L
    source_decision_ids_used <- c(source_decision_ids_used,src_ids)
    r$screening <- list(
      workflow="04_historical_screening_reconciliation",
      implementation_language="R",
      status="historical_decision_applied",
      decision=d,
      source_lens_ids=src_ids,
      propagated_across_deduplication_group=length(group_ids)>1L,
      requires_screening=FALSE,
      publication_status_eligible=publication_ok,
      downstream_eligible=identical(d,"include") && publication_ok
    )
  } else {
    cobj <- list(
      representative_lens_id=id,
      group_lens_ids=group_ids,
      historical_decisions=lapply(
        src_ids,
        function(g)list(lens_id=g,decision=decision_map[[g]])
      )
    )
    override <- historical_conflict_overrides[[id]]
    if (!is.null(override)) {
      d <- as.character(override$decision)
      if (!(d %in% c("include","exclude"))) stop("Invalid historical conflict override")
      counts[d] <- counts[d] + 1L
      source_decision_ids_used <- c(source_decision_ids_used,src_ids)
      r$screening <- list(
        workflow="04_historical_screening_reconciliation",
        implementation_language="R",
        status="historical_decision_conflict_resolved",
        decision=d,
        source_lens_ids=src_ids,
        historical_conflict=cobj$historical_decisions,
        conflict_resolution=list(
          adjudicated_at=now_utc(),
          decision=d,
          rationale=override$rationale
        ),
        requires_screening=FALSE,
        publication_status_eligible=publication_ok,
        downstream_eligible=identical(d,"include") && publication_ok
      )
    } else {
      counts["conflict"] <- counts["conflict"] + 1L
      conflicts[[length(conflicts)+1L]] <- cobj
      r$screening <- list(
        workflow="04_historical_screening_reconciliation",
        implementation_language="R",
        status="historical_decision_conflict",
        decision=NULL,
        requires_screening=FALSE,
        publication_status_eligible=publication_ok,
        downstream_eligible=FALSE,
        conflict=cobj$historical_decisions
      )
    }
  }

  representative_summary[[length(representative_summary)+1L]] <- list(
    lens_id=id,
    deduplication_status=st,
    screening_status=r$screening$status,
    screening_decision=r$screening$decision %||% NULL,
    source_lens_ids=r$screening$source_lens_ids %||% list()
  )
  records[[i]] <- r
}

write_jsonl(records,file.path(output_dir,"annotated_records.jsonl"))
write_jsonl(conflicts,file.path(output_dir,"historical_decision_conflicts.jsonl"))
write_jsonl(
  representative_summary,
  file.path(output_dir,"representative_screening_audit.jsonl")
)
write_jsonl(new_queue,file.path(output_dir,"new_screening_queue.jsonl"))

rep_n <- sum(vapply(
  records,
  function(r)dedup_status(r)%in%c("unique","canonical"),
  logical(1)
))

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
  representatives_not_previously_screened_publication_blocked=unname(counts["publication_blocked_unscreened"]),
  representatives_with_historical_conflict=unname(counts["conflict"]),
  new_screening_queue_records=length(new_queue),
  source_historical_decision_ids_used=length(unique(source_decision_ids_used)),
  manual_adjudication_keys_recovered=matched_manual,
  manual_post_dedup_repair_records=length(manual_dedup_repair_ids),
  historical_conflict_overrides_applied=sum(vapply(records,function(r) identical((r$screening %||% list())$status,"historical_decision_conflict_resolved"),logical(1))),
  implementation_language="R"
)

if (summary$output_records != summary$input_records) {
  stop("One-off historical screening cardinality invariant failed")
}
if (summary$new_screening_queue_records != summary$representatives_not_previously_screened) {
  stop("New-screening queue invariant failed: publication-blocked unscreened records must not be queued")
}
if (summary$representatives_include +
    summary$representatives_exclude +
    summary$representatives_not_previously_screened +
    summary$representatives_not_previously_screened_publication_blocked +
    summary$representatives_with_historical_conflict != rep_n) {
  stop("One-off historical screening representative status count invariant failed")
}

writeLines(
  toJSON(summary,auto_unbox=TRUE,pretty=TRUE,null="null"),
  file.path(output_dir,"historical_screening_summary.json")
)
writeLines(
  toJSON(
    list(
      workflow="oneoff_reapply_historical_screening",
      created_at=now_utc(),
      summary=summary
    ),
    auto_unbox=TRUE,
    pretty=TRUE,
    null="null"
  ),
  file.path(output_dir,"historical_screening_audit.json")
)

message(toJSON(summary,auto_unbox=TRUE,pretty=TRUE))
if (length(conflicts)>0L) {
  message(sprintf(
    "AUDIT REQUIRES REVIEW: %d deduplication groups contain conflicting historical decisions.",
    length(conflicts)
  ))
} else {
  message("PASS: historical screening restoration complete; no historical decision conflicts.")
}
