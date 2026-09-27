#!/usr/bin/env Rscript
suppressPackageStartupMessages({
  library(jsonlite)
  library(readr)
})

args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag, default=NULL) {
  i <- match(flag,args)
  if(is.na(i)) return(default)
  if(i==length(args)) stop(sprintf("Missing value after %s",flag),call.=FALSE)
  args[[i+1L]]
}

scores_path <- arg("--scores")
records_path <- arg("--records")
ontology_path <- arg("--ontology")
zero_rescreen_path <- arg("--zero-rescreen")
output_dir <- arg("--output-dir","outputs/workflow07_topic_final_qc")
if(any(vapply(list(scores_path,records_path,ontology_path,zero_rescreen_path),is.null,logical(1)))) {
  stop("Required: --scores --records --ontology --zero-rescreen",call.=FALSE)
}
dir.create(output_dir,recursive=TRUE,showWarnings=FALSE)

S <- read_csv(scores_path,show_col_types=FALSE,progress=FALSE)
R <- read_csv(records_path,show_col_types=FALSE,progress=FALSE)
`%||%` <- function(x,y) if(is.null(x)||length(x)==0) y else x
O <- read_csv(ontology_path,show_col_types=FALSE,progress=FALSE)
read_jsonl <- function(path){x<-readLines(path,warn=FALSE,encoding="UTF-8");x<-x[nzchar(trimws(x))];lapply(x,jsonlite::fromJSON,simplifyVector=FALSE)}
ZR <- read_jsonl(zero_rescreen_path)

req_s <- c("record_id","path_id","confidence_n","role_a","role_b","role_c")
req_r <- c("record_id")
req_o <- c("path_id","level_1","level_2","hierarchy_path")
if(length(setdiff(req_s,names(S)))) stop("Scores missing required columns: ",paste(setdiff(req_s,names(S)),collapse=", "))
if(length(setdiff(req_r,names(R)))) stop("Record summary missing record_id")
if(length(setdiff(req_o,names(O)))) stop("Ontology missing required columns: ",paste(setdiff(req_o,names(O)),collapse=", "))
if(anyDuplicated(R$record_id)) stop("Duplicate record_id in record summary")
if(anyDuplicated(paste(S$record_id,S$path_id,sep="\r"))) stop("Duplicate record_id/path_id in scores")
if(any(!S$path_id %in% O$path_id)) stop("Unknown path_id in scores")
if(any(!S$confidence_n %in% 1:3)) stop("Invalid confidence_n in scores")
zero_ids <- setdiff(as.character(R$record_id),unique(as.character(S$record_id)))
zr_ids <- vapply(ZR,function(x)as.character(x$record_id %||% ""),character(1))
if(any(!nzchar(zr_ids))||anyDuplicated(zr_ids)) stop("Invalid zero-topic rescreen IDs")
if(!setequal(zero_ids,zr_ids)) stop("Zero-topic rescreen coverage does not match zero-topic records")
zr_dec <- setNames(vapply(ZR,function(x)as.character(x$decision %||% ""),character(1)),zr_ids)
if(any(!zr_dec %in% c("include","exclude","uncertain"))) stop("Invalid zero-topic rescreen decision")

Omap <- O[match(S$path_id,O$path_id),c("path_id","level_1","level_2","hierarchy_path")]
stopifnot(all(Omap$path_id==S$path_id))

present <- function(x) !is.na(x) & nzchar(trimws(as.character(x)))

# Explicit ontology-v3.6 fallback/supersession rules only.
is_superseded_general <- function(pid, assigned_ids) {
  assigned_ids <- unique(as.character(assigned_ids))
  others <- setdiff(assigned_ids,pid)
  if(!length(others)) return(FALSE)
  oo <- O[match(others,O$path_id),,drop=FALSE]
  if(pid=="V3_001") return(any(oo$level_1=="Environment"))
  if(pid=="V3_052") return(any(oo$level_1=="People and society"))
  if(pid=="V3_071") return(any(oo$level_1=="Product"))
  if(pid=="V3_088") return(any(oo$level_2=="Fish health"))
  if(pid=="V3_120") return(any(others %in% c("V3_121","V3_122","V3_123")))
  FALSE
}

S$retained_for_analysis <- FALSE
S$retention_basis <- ""
score_index <- split(seq_len(nrow(S)), as.character(S$record_id))

record_rows <- vector("list",nrow(R))
for(i in seq_len(nrow(R))) {
  rid <- as.character(R$record_id[[i]])
  idx <- score_index[[rid]] %||% integer()
  raw_n <- length(idx)
  if(raw_n==0L) {
    zd <- unname(zr_dec[[rid]])
    route <- if(zd=="uncertain") "human_adjudication" else "none"
    screening_action <- if(zd=="exclude") "late_automatic_exclude" else if(zd=="include") "retain_included_uncoded" else "human_review"
    record_rows[[i]] <- data.frame(
      record_id=rid,topic_count_raw=0L,topic_count_after_general_pruning=0L,
      topic_count_retained=0L,mean_pairwise_jaccard=NA_real_,
      extreme_disagreement=FALSE,zero_topic=TRUE,high_topic_raw=FALSE,
      ontology_pathology=FALSE,zero_topic_rescreen_decision=zd,
      screening_action=screening_action,
      workflow08_reason=if(zd=="uncertain") "zero_topic_eligibility_uncertain" else "",
      workflow08_route=route,
      stringsAsFactors=FALSE)
    next
  }

  ids <- as.character(S$path_id[idx])
  prune <- vapply(ids,is_superseded_general,logical(1),assigned_ids=ids)
  kept_idx <- idx[!prune]
  S$retention_basis[idx[prune]] <- "general_code_superseded_by_specific_code"

  # Soft maximum 10: retain complete confidence tiers. If the highest tier alone
  # exceeds 10, retain that whole highest tier. Never break ties arbitrarily.
  if(length(kept_idx)<=10L) {
    retain_idx <- kept_idx
  } else {
    retain_idx <- integer()
    for(star in 3:1) {
      tier <- kept_idx[S$confidence_n[kept_idx]==star]
      if(!length(tier)) next
      if(!length(retain_idx) && length(tier)>10L) {
        retain_idx <- tier
        break
      }
      if(length(retain_idx)+length(tier)<=10L) {
        retain_idx <- c(retain_idx,tier)
      } else {
        break
      }
    }
  }
  S$retained_for_analysis[retain_idx] <- TRUE
  S$retention_basis[retain_idx] <- if(length(kept_idx)<=10L) "retained_all_after_general_pruning" else "retained_complete_star_tier"
  dropped_cap <- setdiff(kept_idx,retain_idx)
  S$retention_basis[dropped_cap] <- "below_retention_star_threshold"

  pass_sets <- lapply(c("role_a","role_b","role_c"),function(col) ids[present(S[[col]][idx])])
  jac <- function(a,b) {
    u <- union(a,b)
    if(!length(u)) return(1)
    length(intersect(a,b))/length(u)
  }
  j <- c(jac(pass_sets[[1]],pass_sets[[2]]),jac(pass_sets[[1]],pass_sets[[3]]),jac(pass_sets[[2]],pass_sets[[3]]))
  mean_j <- mean(j)

  # All currently documented ontology-v3.6 mutual exclusions are resolved by
  # the deterministic fallback pruning above. Residual pathology is therefore
  # defined as an unresolved V3_120 + V3_121/122/123 combination.
  retained_ids <- as.character(S$path_id[retain_idx])
  pathology <- "V3_120" %in% retained_ids && any(retained_ids %in% c("V3_121","V3_122","V3_123"))
  extreme <- is.finite(mean_j) && mean_j < 0.20

  route <- if(pathology || extreme) "human_adjudication" else "none"
  reason <- if(pathology) "ontology_pathology" else if(extreme) "extreme_three_pass_topic_disagreement" else ""
  record_rows[[i]] <- data.frame(
    record_id=rid,topic_count_raw=raw_n,
    topic_count_after_general_pruning=length(kept_idx),
    topic_count_retained=length(retain_idx),
    mean_pairwise_jaccard=mean_j,
    extreme_disagreement=extreme,zero_topic=FALSE,high_topic_raw=raw_n>10L,
    ontology_pathology=pathology,zero_topic_rescreen_decision="",
    screening_action="retain",
    workflow08_reason=reason,workflow08_route=route,
    stringsAsFactors=FALSE)
}
Q <- do.call(rbind,record_rows)

# Integrity invariants.
if(any(S$retained_for_analysis & S$retention_basis=="")) stop("Retained assignment missing retention basis")
if(any(!S$retained_for_analysis & S$retention_basis=="")) stop("Non-retained assignment missing retention basis")
over10 <- which(Q$topic_count_retained > 10L)
if(length(over10)) {
  expected_tied <- vapply(Q$record_id[over10],function(rid){
    idx <- score_index[[rid]] %||% integer()
    z <- S[idx[!grepl("^general_code",S$retention_basis[idx])],,drop=FALSE]
    if(!nrow(z)) return(0L)
    mx <- max(z$confidence_n)
    sum(z$confidence_n==mx)
  },integer(1))
  if(any(Q$topic_count_retained[over10] != expected_tied)) {
    stop("A >10 retained record is not explained by a highest-tier tie")
  }
}

human <- Q[Q$workflow08_route=="human_adjudication",,drop=FALSE]
zero <- Q[Q$zero_topic,,drop=FALSE]
late_exclude <- Q[Q$screening_action=="late_automatic_exclude",,drop=FALSE]
included_uncoded <- Q[Q$screening_action=="retain_included_uncoded",,drop=FALSE]
high <- Q[Q$high_topic_raw,,drop=FALSE]

write_csv(S,file.path(output_dir,"workflow07_topic_pathway_scores_retained.csv"),na="")
write_csv(Q,file.path(output_dir,"workflow07_topic_record_qc.csv"),na="")
write_csv(human,file.path(output_dir,"workflow07_workflow08_human_review_queue.csv"),na="")
write_csv(zero,file.path(output_dir,"workflow07_zero_topic_rescreen_results.csv"),na="")
write_csv(late_exclude,file.path(output_dir,"workflow07_late_automatic_exclusions.csv"),na="")
write_csv(included_uncoded,file.path(output_dir,"workflow07_included_uncoded.csv"),na="")
write_csv(high,file.path(output_dir,"workflow07_high_topic_automated_qc.csv"),na="")

summary <- list(
  schema="living-evidence-map-workflow07-qc-v1",
  records=nrow(Q),
  raw_topic_assignments=nrow(S),
  retained_topic_assignments=sum(S$retained_for_analysis),
  zero_topic_records=nrow(zero),
  zero_topic_rescreen_include=sum(zero$zero_topic_rescreen_decision=="include"),
  zero_topic_rescreen_exclude=sum(zero$zero_topic_rescreen_decision=="exclude"),
  zero_topic_rescreen_uncertain=sum(zero$zero_topic_rescreen_decision=="uncertain"),
  included_uncoded_records=nrow(included_uncoded),
  late_automatic_exclusions=nrow(late_exclude),
  high_topic_raw_records=nrow(high),
  extreme_disagreement_threshold_mean_pairwise_jaccard=0.20,
  extreme_disagreement_records=sum(Q$extreme_disagreement),
  ontology_pathology_records=sum(Q$ontology_pathology),
  immediate_human_adjudication_records=nrow(human),
  zero_topic_route="targeted eligibility rescreen: include -> retain included-but-uncoded; exclude -> late automatic exclusion; uncertain -> Workflow 08 human adjudication",
  high_topic_rule="prune documented general/fallback codes; retain complete star tiers up to 10; if highest tier itself exceeds 10 retain the full tied tier",
  condition4_definition="residual ontology-semantic incompatibility after deterministic ontology-v3.6 fallback/supersession rules",
  created_at_utc=format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ")
)
write_json(summary,file.path(output_dir,"workflow07_qc_summary.json"),pretty=TRUE,auto_unbox=TRUE,null="null")
writeLines("PASS",file.path(output_dir,"WORKFLOW07_QC_PASS.ok"))
cat(toJSON(summary,pretty=TRUE,auto_unbox=TRUE),"\n")
