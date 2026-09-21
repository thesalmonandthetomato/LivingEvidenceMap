#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(data.table)
  library(digest)
  library(stringdist)
})

args <- commandArgs(trailingOnly = TRUE)
arg <- function(flag, default = NULL) {
  i <- match(flag, args)
  if (is.na(i)) return(default)
  if (i == length(args)) stop(sprintf("Missing value after %s", flag), call. = FALSE)
  args[[i + 1L]]
}

input_dir <- arg("--input-dir")
output_dir <- arg("--output-dir")
target_n <- as.integer(arg("--target-n", "10000"))
sample_key <- arg("--sample-key", "workflow02-v2-expanded-audit-v1")

if (is.null(input_dir) || is.null(output_dir)) {
  stop("Required: --input-dir --output-dir", call. = FALSE)
}
if (is.na(target_n) || target_n < 2000L) stop("--target-n must be >= 2000", call. = FALSE)
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

find_one <- function(name) {
  p <- file.path(input_dir, name)
  if (file.exists(p)) return(p)
  hits <- list.files(input_dir, pattern = paste0("^", gsub("\\.", "\\\\.", name), "$"),
                     recursive = TRUE, full.names = TRUE)
  if (!length(hits)) stop(sprintf("%s not found in saved benchmark artefact", name), call. = FALSE)
  hits[[1L]]
}

meta <- fread(find_one("normalised_metadata.csv"), na.strings = c("", "NA"))
all_pairs <- fread(find_one("all_candidate_pairs.csv"), na.strings = c("", "NA"))
original <- fread(find_one("scored_sample.csv"), na.strings = c("", "NA"))

stopifnot(all(c("idx","title","title_norm","doi_norm","doi_family","abstract_hash",
                "author_norm","year","abstract_norm") %in% names(meta)))
stopifnot(all(c("record_i","record_j","blocks") %in% names(all_pairs)))

pair_key <- function(i,j) paste(pmin(i,j), pmax(i,j), sep="::")
original[, pair_key := pair_key(record_i, record_j)]
all_pairs[, pair_key := pair_key(record_i, record_j)]
all_pairs <- all_pairs[!duplicated(pair_key)]

# Retain every original calibration pair, then add deterministic stratified new pairs.
need <- max(0L, target_n - nrow(original))
pool <- all_pairs[!pair_key %in% original$pair_key]
pool[, primary_block := tstrsplit(blocks, ";", fixed = TRUE, keep = 1L)]
pool[, sample_hash := vapply(seq_len(.N), function(i)
  digest(paste(sample_key, record_i[[i]], record_j[[i]], sep="|"),
         algo="sha256", serialize=FALSE), character(1))]

if (need > 0L) {
  nb <- uniqueN(pool$primary_block)
  per_block <- max(50L, ceiling(need / max(1L, nb)))
  setorder(pool, primary_block, sample_hash)
  extra <- pool[, head(.SD, per_block), by=primary_block]
  if (nrow(extra) > need) {
    setorder(extra, sample_hash)
    extra <- extra[seq_len(need)]
  }
} else {
  extra <- pool[0]
}

score_sample <- rbind(
  original[, .(record_i, record_j, blocks, pair_key, stratum="original_calibration")],
  extra[, .(record_i, record_j, blocks, pair_key, stratum="expanded_stratified")],
  fill=TRUE
)
if (nrow(score_sample) != min(target_n, nrow(all_pairs))) {
  stop(sprintf("Expanded sample size mismatch: got %d expected %d",
               nrow(score_sample), min(target_n, nrow(all_pairs))), call.=FALSE)
}

setkey(meta, idx)
tokens <- function(x) if (is.na(x) || !nzchar(x)) character() else strsplit(x, " ", fixed=TRUE)[[1L]]
shingles5 <- function(t) if (length(t)<5L) character() else unique(vapply(seq_len(length(t)-4L), function(i) paste(t[i:(i+4L)], collapse=" "), character(1)))
lcs_len <- function(a,b) {
  if (!length(a) || !length(b)) return(0L)
  if (length(a)>length(b)) {tmp<-a;a<-b;b<-tmp}
  prev <- integer(length(b)+1L); cur <- integer(length(b)+1L)
  for (i in seq_along(a)) {
    cur[] <- 0L
    for (j in seq_along(b)) cur[[j+1L]] <- if (identical(a[[i]],b[[j]])) prev[[j]]+1L else max(prev[[j+1L]],cur[[j]])
    tmp<-prev;prev<-cur;cur<-tmp
  }
  prev[[length(b)+1L]]
}
abstract_metrics <- function(a,b) {
  ta<-tokens(a);tb<-tokens(b);shorter<-min(length(ta),length(tb))
  if (!shorter) return(list(lcs=0L,ordered=NA_real_,shingle=NA_real_,strong=FALSE))
  sa<-shingles5(ta);sb<-shingles5(tb)
  sh<-if (!length(sa)||!length(sb)) NA_real_ else length(intersect(sa,sb))/min(length(sa),length(sb))
  l<-lcs_len(ta,tb); oc<-l/shorter
  strong <- (l>=80L && oc>=0.90 && !is.na(sh)&&sh>=0.60) ||
            (l>=60L&&l<=79L&&oc>=0.95&&!is.na(sh)&&sh>=0.75)
  list(lcs=l,ordered=oc,shingle=sh,strong=strong)
}

score_one <- function(i,j,blocks) {
  a <- meta[.(i)]; b <- meta[.(j)]
  same_doi <- !is.na(a$doi_norm)&&!is.na(b$doi_norm)&&identical(a$doi_norm,b$doi_norm)
  same_family <- !is.na(a$doi_family)&&!is.na(b$doi_family)&&identical(a$doi_family,b$doi_family)
  diff_doi <- !is.na(a$doi_norm)&&!is.na(b$doi_norm)&&!identical(a$doi_norm,b$doi_norm)
  exact_title <- !is.na(a$title_norm)&&!is.na(b$title_norm)&&identical(a$title_norm,b$title_norm)
  tsim <- if (!is.na(a$title_norm)&&!is.na(b$title_norm)) as.numeric(stringsim(a$title_norm,b$title_norm,method="jw",p=0.1)) else NA_real_
  containment <- FALSE
  if (!is.na(a$title_norm)&&!is.na(b$title_norm)) {
    short <- if(nchar(a$title_norm)<=nchar(b$title_norm)) a$title_norm else b$title_norm
    long <- if(nchar(a$title_norm)<=nchar(b$title_norm)) b$title_norm else a$title_norm
    containment <- nchar(short)>=30L && grepl(short,long,fixed=TRUE)
  }
  exact_abs <- !is.na(a$abstract_hash)&&!is.na(b$abstract_hash)&&identical(a$abstract_hash,b$abstract_hash)
  exact_author <- !is.na(a$author_norm)&&!is.na(b$author_norm)&&identical(a$author_norm,b$author_norm)
  exact_year <- !is.na(a$year)&&!is.na(b$year)&&identical(a$year,b$year)
  yd <- if (!is.na(a$year)&&!is.na(b$year)) abs(a$year-b$year) else NA_integer_
  brA <- grepl("(^|;)bramer_A(;|$)",blocks)
  brB <- grepl("(^|;)bramer_B(;|$)",blocks)
  need_abs <- !exact_abs && !is.na(tsim) && (tsim>=0.90||containment||exact_title)
  am <- if (need_abs && !is.na(a$abstract_norm)&&!is.na(b$abstract_norm))
          abstract_metrics(a$abstract_norm,b$abstract_norm)
        else list(lcs=NA_integer_,ordered=NA_real_,shingle=NA_real_,strong=FALSE)

  auto <- NULL
  if(brA)auto<-"bramer_A"
  else if(brB)auto<-"bramer_B"
  else if(same_doi&&exact_title)auto<-"exact_doi_exact_title"
  else if(exact_title&&exact_abs)auto<-"exact_title_exact_abstract"
  else if(same_doi&&containment)auto<-"exact_doi_title_containment"
  else if(same_doi&&!is.na(tsim)&&tsim>=0.985)auto<-"exact_doi_title_similarity_0.985"
  else if(same_doi&&exact_abs)auto<-"exact_doi_exact_abstract"
  else if(exact_title&&am$strong)auto<-"exact_title_strong_abstract"
  else if(containment&&am$strong)auto<-"title_containment_strong_abstract"
  else if(!is.na(tsim)&&tsim>=0.97&&am$strong)auto<-"title_similarity_0.97_strong_abstract"
  else if(!is.na(tsim)&&tsim>=0.95&&exact_author&&exact_year)auto<-"title_similarity_0.95_exact_author_year"

  cls <- "unresolved"; rule <- "candidate_only"
  if(!is.null(auto)) {
    if(diff_doi&&!same_family&&!grepl("^exact_doi_",auto)) {cls<-"review";rule<-"material_conflict_different_doi"}
    else {cls<-"duplicate";rule<-auto}
  } else if(exact_abs) {cls<-"review";rule<-"exact_abstract_insufficient_metadata"}
  else if(same_family&&diff_doi&&!is.na(tsim)&&tsim>=0.97) {cls<-"review";rule<-"doi_family_title_similarity_0.97"}
  else if(exact_title&&!is.na(yd)&&yd<=1L) {cls<-"review";rule<-"exact_title_year_within_1"}
  else if(am$strong&&diff_doi&&!same_family) {cls<-"review";rule<-"strong_content_material_doi_conflict"}

  data.table(record_i=i,record_j=j,source_i=a$source,source_j=b$source,
             title_i=a$title,title_j=b$title,doi_i=a$doi_norm,doi_j=b$doi_norm,
             blocks=blocks,title_similarity=tsim,title_containment=containment,
             exact_title=exact_title,exact_abstract=exact_abs,
             ordered_coverage=am$ordered,shingle_containment=am$shingle,lcs_tokens=am$lcs,
             classification=cls,rule=rule)
}

out <- vector("list", nrow(score_sample))
for (k in seq_len(nrow(score_sample))) {
  out[[k]] <- score_one(score_sample$record_i[[k]], score_sample$record_j[[k]], score_sample$blocks[[k]])
  if (k %% 500L == 0L || k == nrow(score_sample)) {
    cat(sprintf("Scored %d / %d pairs\n", k, nrow(score_sample)))
    flush.console()
  }
}
scored <- rbindlist(out, fill=TRUE)
scored[, stratum := score_sample$stratum]

# Preserve the exact original 2,000 scored rows to guarantee comparability.
orig_keys <- original$pair_key
scored[, pair_key := pair_key(record_i,record_j)]
setkey(scored,pair_key); setkey(original,pair_key)
common <- intersect(orig_keys, scored$pair_key)
if (length(common) != nrow(original)) stop("Original calibration pairs missing from expanded sample", call.=FALSE)

fwrite(scored[, !"pair_key"], file.path(output_dir,"scored_sample.csv"))
fwrite(meta, file.path(output_dir,"normalised_metadata.csv"))
fwrite(score_sample[, .(record_i,record_j,blocks,stratum)], file.path(output_dir,"expanded_scoring_sample.csv"))

summary <- list(
  status="success",
  source_candidate_artifact_reused=TRUE,
  candidate_generation_repeated=FALSE,
  total_candidate_pairs=nrow(all_pairs),
  original_calibration_pairs=nrow(original),
  expanded_pairs=nrow(extra),
  scoring_sample_n=nrow(scored),
  stratum_counts=as.list(table(scored$stratum)),
  base_classification_counts=as.list(table(scored$classification)),
  base_rule_counts=as.list(table(scored$rule))
)
writeLines(jsonlite::toJSON(summary,auto_unbox=TRUE,pretty=TRUE,null="null",na="null"),
           file.path(output_dir,"expanded_summary.json"))
cat(jsonlite::toJSON(summary,auto_unbox=TRUE,pretty=TRUE,null="null",na="null"),"\n")
