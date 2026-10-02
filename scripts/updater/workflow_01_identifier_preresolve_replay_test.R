#!/usr/bin/env Rscript
suppressPackageStartupMessages({
  library(data.table)
  library(jsonlite)
})

args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag,default=NULL) {
  i <- match(flag,args)
  if (is.na(i)) return(default)
  if (i==length(args)) stop(sprintf("Missing value after %s",flag),call.=FALSE)
  args[[i+1L]]
}
pairs_path <- arg("--identifier-pairs")
registry_path <- arg("--registry")
guards_path <- arg("--guards")
w01_metadata_path <- arg("--w01-metadata")
w01_scored_path <- arg("--w01-scored")
high_triage_path <- arg("--high-triage")
high_external_path <- arg("--high-external")
single_triage_path <- arg("--single-triage")
single_external_path <- arg("--single-external")
output_dir <- arg("--output-dir")
req <- list(pairs_path,registry_path,guards_path,w01_metadata_path,w01_scored_path,
            high_triage_path,high_external_path,single_triage_path,single_external_path,output_dir)
if (any(vapply(req,is.null,logical(1)))) stop("All input flags plus --output-dir are required",call.=FALSE)
dir.create(output_dir,recursive=TRUE,showWarnings=FALSE)

pair_key <- function(a,b) paste(pmin(as.character(a),as.character(b)),pmax(as.character(a),as.character(b)),sep="||")
idx_key <- function(a,b) paste(pmin(as.integer(a),as.integer(b)),pmax(as.integer(a),as.integer(b)),sep="::")
title_sim <- function(a,b) {
  if (is.na(a)||is.na(b)||!nzchar(a)||!nzchar(b)) return(NA_real_)
  1 - adist(a,b)[1L] / max(nchar(a),nchar(b),1L)
}

x <- fread(pairs_path,na.strings=c("","NA"))
if (!("record_i" %in% names(x)) && "i.manifestation_key" %in% names(x)) setnames(x,"i.manifestation_key","record_i")
if (!("record_j" %in% names(x)) && "manifestation_key" %in% names(x)) setnames(x,"manifestation_key","record_j")
need <- c("record_i","record_j","families","n_independent_families","same_cluster","year_diff","involves_appended","title_i","title_j")
if (length(setdiff(need,names(x)))) stop("Identifier pair table missing required fields",call.=FALSE)

reg <- fread(registry_path,na.strings=c("","NA"))
g <- fread(guards_path,na.strings=c("","NA"))
stopifnot(all(c("manifestation_key","identifier_type","identifier_value") %in% names(reg)))
stopifnot(all(c("identifier_type","identifier_value") %in% names(g)))

# Exact empirical reused/container guards only. Historical W01 disagreement is NOT
# itself a guard, because the purpose of this replay is to test whether identifier
# evidence can safely recover genuine W01 misses.
reg_i <- reg[,.(record_i=manifestation_key,identifier_type,identifier_value)]
reg_j <- reg[,.(record_j=manifestation_key,identifier_type,identifier_value)]
shared_guard <- merge(
  merge(reg_i,reg_j,by=c("identifier_type","identifier_value"),allow.cartesian=TRUE),
  unique(g[,.(identifier_type,identifier_value)]),
  by=c("identifier_type","identifier_value"),
  all=FALSE
)
shared_guard <- shared_guard[record_i < record_j,.(empirical_guard=TRUE),by=.(record_i,record_j)]
setkey(x,record_i,record_j)
setkey(shared_guard,record_i,record_j)
x <- shared_guard[x]
x[is.na(empirical_guard),empirical_guard:=FALSE]

x[, title_similarity := mapply(title_sim,title_i,title_j)]
x[, year_compatible := is.na(year_diff) | year_diff<=1L]
x[, safe_identifier_preresolve := FALSE]
x[
  !empirical_guard & year_compatible & !is.na(title_similarity) &
  n_independent_families>=2L & title_similarity>=0.65,
  safe_identifier_preresolve := TRUE
]
x[
  !empirical_guard & year_compatible & !is.na(title_similarity) &
  n_independent_families==1L & families=="doi" & title_similarity>=0.90,
  safe_identifier_preresolve := TRUE
]
x[
  !empirical_guard & year_compatible & !is.na(title_similarity) &
  n_independent_families==1L & families %in% c("pmid","openalex_mag") & title_similarity>=0.65,
  safe_identifier_preresolve := TRUE
]
x[, pair_key := pair_key(record_i,record_j)]

# Validation gold set: 235 supported multi-family misses + one unsafe container case.
ht <- fread(high_triage_path,na.strings=c("","NA"))
if ("i.manifestation_key" %in% names(ht)) setnames(ht,"i.manifestation_key","record_i")
if ("manifestation_key" %in% names(ht)) setnames(ht,"manifestation_key","record_j")
he <- fread(high_external_path,na.strings=c("","NA"))
ht[, gold := fifelse(triage_class=="likely_w01_miss","same","unknown")]
he_class <- setNames(he$external_validation_class,he$pair_id)
for (i in seq_len(nrow(ht))) {
  if (ht$gold[[i]]=="same") next
  pid <- ht$pair_id[[i]]
  cl <- unname(he_class[[pid]])
  if (pid %in% c("H0036","H0224")) ht$gold[[i]] <- "same"
  else if (pid=="H0173") ht$gold[[i]] <- "unsafe"
  else if (!is.null(cl) && cl %in% c("externally_corroborated_same_work","external_metadata_support_no_direct_crosswalk")) ht$gold[[i]] <- "same"
  else ht$gold[[i]] <- "unsafe"
}
ht[, pair_key := pair_key(record_i,record_j)]

# Validation gold set: 856 supported single-family misses + 363 risky/unresolved.
st <- fread(single_triage_path,na.strings=c("","NA"))
if ("i.manifestation_key" %in% names(st)) setnames(st,"i.manifestation_key","record_i")
if ("manifestation_key" %in% names(st)) setnames(st,"manifestation_key","record_j")
se <- fread(single_external_path,na.strings=c("","NA"))
st[, gold := fifelse(triage_class=="strong_same_work_candidate","same","unsafe")]
se[, pair_key := pair_key(record_i,record_j)]
same_ext <- unique(se[external_validation_class %in% c(
  "externally_corroborated_same_work","pair_supported_but_canonical_title_variant"
),pair_key])
st[, pair_key := pair_key(record_i,record_j)]
st[pair_key %in% same_ext,gold:="same"]

gold <- rbind(
  ht[,.(pair_key,gold,gold_family="multi")],
  st[,.(pair_key,gold,gold_family="single")]
)
if (sum(gold$gold=="same")!=1091L) stop("Expected 1,091 validated same-work misses",call.=FALSE)
if (sum(gold$gold=="unsafe")!=364L) stop("Expected 364 validated unsafe/risky cases",call.=FALSE)

safe_keys <- unique(x[safe_identifier_preresolve==TRUE,pair_key])
gold[, fast_tracked := pair_key %in% safe_keys]
validated_recovered <- sum(gold$gold=="same" & gold$fast_tracked)
validated_unsafe_fast_tracked <- sum(gold$gold=="unsafe" & gold$fast_tracked)
multi_recovered <- sum(gold$gold=="same" & gold$gold_family=="multi" & gold$fast_tracked)
single_recovered <- sum(gold$gold=="same" & gold$gold_family=="single" & gold$fast_tracked)

# Replay against actual saved W01 candidate/scoring workload.
meta <- fread(w01_metadata_path,select=c("idx","source","source_record_id"),na.strings=c("","NA"))
meta[, manifestation_key := paste(source,source_record_id,sep="::")]
idx_map <- setNames(meta$idx,meta$manifestation_key)

safe_app <- x[safe_identifier_preresolve==TRUE & involves_appended==TRUE,
              .(record_i,record_j,pair_key)]
safe_app[, idx_i := as.integer(idx_map[record_i])]
safe_app[, idx_j := as.integer(idx_map[record_j])]
if (anyNA(safe_app$idx_i)||anyNA(safe_app$idx_j)) stop("Safe identifier pair did not map to W01 manifestation index",call.=FALSE)
safe_app[, idx_pair_key := idx_key(idx_i,idx_j)]
safe_idx_keys <- unique(safe_app$idx_pair_key)

scored <- fread(w01_scored_path,select=c("record_i","record_j"))
scored[, idx_pair_key := idx_key(record_i,record_j)]
unique_w01_keys <- unique(scored$idx_pair_key)
intersection <- intersect(safe_idx_keys,unique_w01_keys)
missing_from_w01 <- setdiff(safe_idx_keys,unique_w01_keys)

unique_before <- length(unique_w01_keys)
unique_removed <- length(intersection)
unique_after <- unique_before - unique_removed
row_before <- nrow(scored)
row_after <- sum(!(scored$idx_pair_key %in% safe_idx_keys))

audit <- list(
  schema="living-evidence-map-w01-identifier-preresolve-replay-v1",
  status="success",
  test_only=TRUE,
  rule=list(
    empirical_guard_groups=nrow(g),
    multi_family="year compatible + title similarity >= 0.65",
    doi_only="year compatible + title similarity >= 0.90",
    pmid_or_openalex_mag_only="year compatible + title similarity >= 0.65"
  ),
  validation=list(
    validated_w01_misses=1091L,
    validated_w01_misses_recovered=validated_recovered,
    recovery_percent=100*validated_recovered/1091,
    multi_family_recovered=multi_recovered,
    single_family_recovered=single_recovered,
    validated_unsafe_or_risky=364L,
    unsafe_or_risky_fast_tracked=validated_unsafe_fast_tracked
  ),
  replay=list(
    w01_unique_candidate_pairs_before=unique_before,
    safe_identifier_pairs_involving_appended=nrow(safe_app),
    safe_pairs_present_in_w01_candidates=unique_removed,
    safe_pairs_missing_from_w01_candidates=length(missing_from_w01),
    w01_unique_candidate_pairs_after_preresolve=unique_after,
    unique_candidate_pair_reduction_percent=100*unique_removed/unique_before,
    scored_rows_before=row_before,
    scored_rows_after_preresolve=row_after,
    scored_row_reduction=row_before-row_after,
    scored_row_reduction_percent=100*(row_before-row_after)/row_before
  ),
  safety=list(
    automatic_merges_performed=0L,
    production_w01_modified=FALSE
  ),
  interpretation=c(
    "This replay measures candidate-pair materialisation/scoring avoided if safe identifier pairs are registered before ordinary W01 pair scoring.",
    "It does not claim an equivalent reduction in total Workflow 01 wall-clock time because blocking/enumeration overhead and downstream work are not replayed here."
  )
)

stopifnot(validated_recovered==892L)
stopifnot(multi_recovered==181L)
stopifnot(single_recovered==711L)
stopifnot(validated_unsafe_fast_tracked==0L)
stopifnot(nrow(safe_app)==41268L)
stopifnot(unique_removed==41268L)
stopifnot(length(missing_from_w01)==0L)
stopifnot(unique_before==503245L)
stopifnot(unique_after==461977L)

fwrite(x[safe_identifier_preresolve==TRUE],
       file.path(output_dir,"safe_identifier_preresolve_pairs.csv"))
fwrite(safe_app,file.path(output_dir,"safe_identifier_preresolve_appended_pairs.csv"))
fwrite(gold,file.path(output_dir,"validation_gold_routing.csv"))
writeLines(toJSON(audit,auto_unbox=TRUE,pretty=TRUE,null="null",na="null"),
           file.path(output_dir,"identifier_preresolve_replay_audit.json"))

cat("PASS: identifier pre-resolution replay complete\n")
cat(toJSON(audit,auto_unbox=TRUE,pretty=TRUE,null="null",na="null"),"\n")
