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
meta_path <- arg("--metadata")
safe_path <- arg("--safe-pairs")
scored_path <- arg("--scored-pairs")
prior_n <- as.integer(arg("--prior-n"))
out_dir <- arg("--output-dir")
if (is.null(meta_path)||is.null(safe_path)||is.null(scored_path)||is.na(prior_n)||is.null(out_dir)) {
  stop("Required: --metadata --safe-pairs --scored-pairs --prior-n --output-dir",call.=FALSE)
}
dir.create(out_dir,recursive=TRUE,showWarnings=FALSE)

meta <- fread(meta_path,select=c("idx","source","source_record_id"))
if (!identical(as.integer(meta$idx),seq_len(nrow(meta)))) stop("metadata idx must be contiguous",call.=FALSE)
meta[, manifestation_key := paste(source,source_record_id,sep="::")]
idx_map <- setNames(meta$idx,meta$manifestation_key)

safe <- fread(safe_path,na.strings=c("","NA"))
stopifnot(all(c("record_i","record_j") %in% names(safe)))
safe[, idx_i := as.integer(idx_map[record_i])]
safe[, idx_j := as.integer(idx_map[record_j])]
if (anyNA(safe$idx_i)||anyNA(safe$idx_j)) stop("safe identifier pair did not resolve to metadata idx",call.=FALSE)

# Rebuild exactly the same provisional components used by the component benchmark.
parent <- seq_len(nrow(meta))
find_root <- function(x) {
  while (parent[[x]] != x) {
    parent[[x]] <<- parent[[parent[[x]]]]
    x <- parent[[x]]
  }
  x
}
union_pair <- function(a,b) {
  ra <- find_root(a); rb <- find_root(b)
  if (ra==rb) return(invisible(NULL))
  pa <- ra <= prior_n; pb <- rb <= prior_n
  if (pa && !pb) parent[[rb]] <<- ra
  else if (pb && !pa) parent[[ra]] <<- rb
  else if (ra < rb) parent[[rb]] <<- ra
  else parent[[ra]] <<- rb
}
for (i in seq_len(nrow(safe))) union_pair(safe$idx_i[[i]],safe$idx_j[[i]])
component <- vapply(seq_len(nrow(meta)),find_root,integer(1))
meta[, component := component]
comp_map <- setNames(meta$component,meta$idx)

# Load the frozen W01 rescored candidate table. Final classifications are used
# ONLY after deterministic pair selection to validate that the cheap selector
# preserved the existing W01 component-level outcome.
x <- fread(scored_path,na.strings=c("","NA"))
required <- c("record_i","record_j","blocks","doi_i","doi_j","title_similarity",
              "title_containment","exact_title","exact_abstract",
              "first_author_match","year_diff_vec","rescored_classification","rescored_rule")
missing <- setdiff(required,names(x))
if (length(missing)) stop(sprintf("rescored table missing: %s",paste(missing,collapse=", ")),call.=FALSE)

# The saved rescored table contains 1,755 duplicate rows introduced by the
# calibration/rescore handoff. Collapse to the production candidate identity
# before any component-level analysis.
x[, pair_key := paste(pmin(record_i,record_j),pmax(record_i,record_j),sep="::")]
if ("source_row_index" %in% names(x)) setorder(x,pair_key,source_row_index) else setorder(x,pair_key)
x <- unique(x,by="pair_key")
if (nrow(x)!=503245L) stop(sprintf("Expected 503245 unique frozen W01 candidates, got %d",nrow(x)),call.=FALSE)

x[, component_i := as.integer(comp_map[as.character(record_i)])]
x[, component_j := as.integer(comp_map[as.character(record_j)])]
if (anyNA(x$component_i)||anyNA(x$component_j)) stop("candidate did not resolve to provisional component",call.=FALSE)
x[, internal_preresolved := component_i==component_j]
internal_n <- sum(x$internal_preresolved)

external <- x[internal_preresolved==FALSE]
external[, component_key := paste(pmin(component_i,component_j),pmax(component_i,component_j),sep="::")]

# Deterministic cheap selector. It deliberately excludes ordered abstract
# coverage, shingle containment, LCS tokens, existing classification/rule, and
# all downstream adjudication fields. Every feature below is already available
# from ordinary blocking or inexpensive metadata comparison.
has_block <- function(blocks,name) grepl(paste0("(^|;)",name,"(;|$)"),blocks,perl=TRUE)
external[, exact_same_doi := !is.na(doi_i)&nzchar(doi_i)&!is.na(doi_j)&nzchar(doi_j)&doi_i==doi_j]
external[, cheap_score :=
  120*has_block(blocks,"bramer_A") +
  110*has_block(blocks,"bramer_B") +
  100*exact_same_doi +
   90*(exact_title %in% TRUE) +
   80*(exact_abstract %in% TRUE) +
   40*(title_containment %in% TRUE) +
   50*fifelse(is.na(title_similarity),0,pmax(0,title_similarity)) +
   20*(first_author_match %in% TRUE) +
   15*(!is.na(year_diff_vec)&year_diff_vec<=1) +
   10*has_block(blocks,"doi_family") +
   10*has_block(blocks,"abstract_hash")
]

# Reference component outcome: if any manifestation pair is an automatic
# duplicate, the component relation is duplicate; otherwise review dominates
# unresolved. This is validation only and never influences selected_pair.
reference <- external[, .(
  reference_class = if (any(rescored_classification=="duplicate",na.rm=TRUE)) "duplicate"
                    else if (any(rescored_classification=="review",na.rm=TRUE)) "review"
                    else "unresolved",
  manifestation_pairs=.N
),by=component_key]

setorder(external,component_key,-cheap_score,-title_similarity,record_i,record_j,na.last=TRUE)
selected <- external[, .SD[1L],by=component_key]
selected <- reference[selected,on="component_key"]
selected[, class_match := rescored_classification==reference_class]

mismatch <- selected[class_match!=TRUE | is.na(class_match)]
if (nrow(mismatch)) {
  fwrite(mismatch,file.path(out_dir,"ERROR_component_selector_classification_mismatch.csv"))
  stop(sprintf("Cheap selector changed %d component-level W01 outcomes",nrow(mismatch)),call.=FALSE)
}

ref_counts <- reference[,.N,by=reference_class]
sel_counts <- selected[,.N,by=rescored_classification]
setnames(ref_counts,c("reference_class","N"),c("class","reference_n"))
setnames(sel_counts,c("rescored_classification","N"),c("class","selected_n"))
class_counts <- merge(ref_counts,sel_counts,by="class",all=TRUE)
class_counts[is.na(reference_n),reference_n:=0L]
class_counts[is.na(selected_n),selected_n:=0L]

summary <- list(
  schema="living-evidence-map-w01-component-prescore-collapse-test-v1",
  status="success",
  test_only=TRUE,
  input=list(
    unique_manifestation_candidate_pairs=nrow(x),
    safe_identifier_edges=nrow(safe),
    provisional_components=uniqueN(meta$component)
  ),
  collapse=list(
    internal_safe_candidate_pairs_eliminated=internal_n,
    external_unique_component_relations=uniqueN(external$component_key),
    candidate_pairs_selected_for_expensive_scoring=nrow(selected),
    scoring_decisions_avoided=nrow(x)-nrow(selected),
    scoring_decision_reduction_percent=100*(nrow(x)-nrow(selected))/nrow(x),
    mean_manifestation_pairs_per_component_relation=mean(reference$manifestation_pairs),
    max_manifestation_pairs_per_component_relation=max(reference$manifestation_pairs)
  ),
  validation=list(
    component_relations_checked=nrow(selected),
    component_level_classification_matches=sum(selected$class_match),
    component_level_classification_mismatches=nrow(mismatch),
    classification_agreement_percent=100*mean(selected$class_match),
    reference_class_counts=as.list(setNames(class_counts$reference_n,class_counts$class)),
    selected_class_counts=as.list(setNames(class_counts$selected_n,class_counts$class))
  ),
  selector=list(
    uses_expensive_abstract_lcs=FALSE,
    uses_shingle_containment=FALSE,
    uses_existing_classification=FALSE,
    uses_existing_rule=FALSE,
    features=c("blocking evidence","exact DOI","exact title","exact abstract hash",
               "title containment","title similarity","first-author match",
               "year compatibility")
  ),
  safety=list(
    automatic_merges_performed=0L,
    production_w01_modified=FALSE
  ),
  interpretation=c(
    "Keep current W01 manifestation-level candidate discovery unchanged.",
    "After identifier-safe provisional components are known, collapse the candidate table to one deterministically selected manifestation pair per external component relation before expensive content scoring.",
    "The frozen validation shows no loss or change in W01 component-level duplicate/review/unresolved outcomes."
  )
)

stopifnot(internal_n==41271L)
stopifnot(nrow(selected)==272169L)
stopifnot(nrow(x)-nrow(selected)==231076L)
stopifnot(nrow(mismatch)==0L)

fwrite(selected,file.path(out_dir,"selected_component_pairs_for_scoring.csv"))
fwrite(reference,file.path(out_dir,"component_reference_outcomes.csv"))
fwrite(class_counts,file.path(out_dir,"classification_counts.csv"))
writeLines(toJSON(summary,auto_unbox=TRUE,pretty=TRUE,null="null",na="null"),
           file.path(out_dir,"component_prescore_collapse_summary.json"))

cat("PASS: component pre-score collapse preserved all frozen W01 component outcomes\n")
cat(toJSON(summary,auto_unbox=TRUE,pretty=TRUE,null="null",na="null"),"\n")
