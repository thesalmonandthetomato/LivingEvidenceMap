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
prior_n <- as.integer(arg("--prior-n"))
out_dir <- arg("--output-dir")
if (is.null(meta_path)||is.null(safe_path)||is.na(prior_n)||is.null(out_dir)) {
  stop("Required: --metadata --safe-pairs --prior-n --output-dir",call.=FALSE)
}
dir.create(out_dir,recursive=TRUE,showWarnings=FALSE)

meta <- fread(meta_path,na.strings=c("","NA"))
req <- c("idx","source","source_record_id","title_norm","doi_norm","doi_family",
         "abstract_hash","author_norm","year","journal_norm","volume_norm",
         "issue_norm","pages_norm")
miss <- setdiff(req,names(meta))
if (length(miss)) stop(sprintf("metadata missing: %s",paste(miss,collapse=", ")),call.=FALSE)
if (!identical(as.integer(meta$idx),seq_len(nrow(meta)))) stop("idx must be contiguous",call.=FALSE)
if (prior_n<1L || prior_n>=nrow(meta)) stop("invalid --prior-n",call.=FALSE)
meta[, manifestation_key := paste(source,source_record_id,sep="::")]
idx_map <- setNames(meta$idx,meta$manifestation_key)
meta[, appended := idx > prior_n]

safe <- fread(safe_path,na.strings=c("","NA"))
stopifnot(all(c("record_i","record_j") %in% names(safe)))
safe[, idx_i := as.integer(idx_map[record_i])]
safe[, idx_j := as.integer(idx_map[record_j])]
if (anyNA(safe$idx_i)||anyNA(safe$idx_j)) stop("safe pair did not resolve to metadata idx",call.=FALSE)

# Union-find only for validated-safe pre-resolution edges.
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
  # deterministic representative: prefer prior manifestation, then lower idx.
  pa <- ra <= prior_n; pb <- rb <= prior_n
  if (pa && !pb) parent[[rb]] <<- ra
  else if (pb && !pa) parent[[ra]] <<- rb
  else if (ra < rb) parent[[rb]] <<- ra
  else parent[[ra]] <<- rb
}
for (i in seq_len(nrow(safe))) union_pair(safe$idx_i[[i]],safe$idx_j[[i]])
component <- vapply(seq_len(nrow(meta)),find_root,integer(1))
meta[, component := component]
comp <- meta[, .(
  members=.N,
  has_appended=any(appended),
  has_prior=any(!appended),
  min_title_len=suppressWarnings(min(nchar(title_norm)[!is.na(title_norm)],na.rm=TRUE)),
  max_title_len=suppressWarnings(max(nchar(title_norm)[!is.na(title_norm)],na.rm=TRUE))
),by=component]
comp[!is.finite(min_title_len),min_title_len:=NA_real_]
comp[!is.finite(max_title_len),max_title_len:=NA_real_]
setkey(comp,component)

key_complete <- function(...) {
  xs <- list(...); n <- length(xs[[1L]]); out <- rep(NA_character_,n); ok <- rep(TRUE,n)
  for (x in xs) ok <- ok & !is.na(x) & nzchar(as.character(x))
  if (any(ok)) out[ok] <- do.call(paste,c(lapply(xs,function(x)x[ok]),sep="::"))
  out
}
meta[,bramer_A:=key_complete(author_norm,year,title_norm,journal_norm)]
meta[,bramer_B:=key_complete(author_norm,year,title_norm,pages_norm)]
meta[,bramer_C:=key_complete(title_norm,volume_norm,pages_norm)]
meta[,bramer_D:=key_complete(author_norm,volume_norm,pages_norm)]
meta[,bramer_E:=key_complete(year,volume_norm,issue_norm,pages_norm)]
meta[,bramer_F:=title_norm]
meta[,bramer_G:=key_complete(author_norm,year)]
block_names <- c("bramer_A","bramer_B","bramer_C","bramer_D","bramer_E","bramer_F","bramer_G",
                 "doi_norm","doi_family","abstract_hash")

pair_env <- function() new.env(hash=TRUE,parent=emptyenv())
add_pair <- function(env,a,b,block) {
  if (a==b) return(invisible(FALSE))
  aa <- min(a,b); bb <- max(a,b)
  # component pair is incremental if either component contains appended manifestation.
  if (!comp[.(aa)]$has_appended && !comp[.(bb)]$has_appended) return(invisible(FALSE))
  k <- paste(aa,bb,sep="::")
  if (!exists(k,env,inherits=FALSE)) {
    assign(k,list(i=aa,j=bb,blocks=block),env)
    TRUE
  } else {
    z <- get(k,env,inherits=FALSE)
    z$blocks <- unique(c(z$blocks,block))
    assign(k,z,env)
    FALSE
  }
}

# Baseline generator recreates the production blocking logic over manifestations.
generate_baseline <- function() {
  env <- pair_env()
  add_group <- function(col,block,max_group=500L) {
    x <- meta[!is.na(get(col)) & nzchar(get(col)),.(idx,key=get(col))]
    eligible <- x[,.N,by=key][N>1L & N<=max_group,key]
    x <- x[key %in% eligible]
    split_idx <- split(x$idx,x$key)
    for (v in split_idx) if (length(v)>=2L) {
      cmb <- combn(v,2L)
      for (j in seq_len(ncol(cmb))) {
        a <- cmb[1L,j]; b <- cmb[2L,j]
        if (a<=prior_n && b<=prior_n) next
        k <- paste(min(a,b),max(a,b),sep="::")
        if (!exists(k,env,inherits=FALSE)) assign(k,list(i=min(a,b),j=max(a,b),blocks=block),env)
        else {
          z <- get(k,env,inherits=FALSE); z$blocks <- unique(c(z$blocks,block)); assign(k,z,env)
        }
      }
    }
  }
  for (bn in block_names) add_group(bn,bn)

  qrows <- vector("list",nrow(meta))
  for (i in seq_len(nrow(meta))) {
    s <- meta$title_norm[[i]]
    if (is.na(s) || nchar(s,type="chars")<4L) next
    n <- nchar(s,type="chars")
    qs <- unique(vapply(seq_len(n-3L),function(k) substr(s,k,k+3L),character(1)))
    qrows[[i]] <- data.table(idx=i,qgram=qs)
  }
  qdt <- rbindlist(qrows,use.names=TRUE,fill=TRUE)
  qfreq <- qdt[,.(df=uniqueN(idx)),by=qgram]
  setkey(qfreq,qgram); qdt <- qfreq[qdt,on="qgram"]
  setorder(qdt,idx,df,qgram)
  sig <- qdt[,head(.SD,10L),by=idx]
  setkey(sig,qgram)
  cand <- sig[sig,allow.cartesian=TRUE,nomatch=0L][idx < i.idx,
    .(shared_rare_qgrams=.N),by=.(record_i=idx,record_j=i.idx)]
  cand <- cand[shared_rare_qgrams>=2L]
  lens <- nchar(meta$title_norm,type="chars")
  cand[,len_ratio:=pmin(lens[record_i],lens[record_j])/pmax(lens[record_i],lens[record_j])]
  cand <- cand[is.finite(len_ratio)&len_ratio>=0.75]
  cand <- cand[record_i>prior_n | record_j>prior_n]
  for (k in seq_len(nrow(cand))) {
    a <- cand$record_i[[k]]; b <- cand$record_j[[k]]
    key <- paste(a,b,sep="::")
    if (!exists(key,env,inherits=FALSE)) assign(key,list(i=a,j=b,blocks="rare_qgram_title"),env)
    else {
      z <- get(key,env,inherits=FALSE); z$blocks <- unique(c(z$blocks,"rare_qgram_title")); assign(key,z,env)
    }
  }
  keys <- ls(env,all.names=TRUE)
  out <- rbindlist(lapply(keys,function(k) {
    z <- get(k,env,inherits=FALSE); data.table(record_i=z$i,record_j=z$j,blocks=paste(sort(unique(z$blocks)),collapse=";"))
  }))
  out
}

# Component-aware generator uses all member metadata signatures but materialises
# candidates between provisional publication components, never within a safely
# pre-resolved component.
generate_component <- function() {
  env <- pair_env()
  for (bn in block_names) {
    x <- meta[!is.na(get(bn)) & nzchar(get(bn)),.(idx,component,key=get(bn))]
    # Preserve production's max-group guard using manifestation cardinality.
    eligible <- x[,.N,by=key][N>1L & N<=500L,key]
    x <- unique(x[key %in% eligible,.(component,key)])
    spl <- split(x$component,x$key)
    for (v in spl) {
      v <- unique(v)
      if (length(v)<2L) next
      cmb <- combn(v,2L)
      for (j in seq_len(ncol(cmb))) add_pair(env,cmb[1L,j],cmb[2L,j],bn)
    }
  }

  # Rare-qgram signatures are still extracted per title, preserving all member
  # evidence. Signatures are then unioned at component level before the join.
  qrows <- vector("list",nrow(meta))
  for (i in seq_len(nrow(meta))) {
    s <- meta$title_norm[[i]]
    if (is.na(s) || nchar(s,type="chars")<4L) next
    n <- nchar(s,type="chars")
    qs <- unique(vapply(seq_len(n-3L),function(k) substr(s,k,k+3L),character(1)))
    qrows[[i]] <- data.table(idx=i,qgram=qs)
  }
  qdt <- rbindlist(qrows,use.names=TRUE,fill=TRUE)
  qfreq <- qdt[,.(df=uniqueN(idx)),by=qgram]
  setkey(qfreq,qgram); qdt <- qfreq[qdt,on="qgram"]
  setorder(qdt,idx,df,qgram)
  sig <- qdt[,head(.SD,10L),by=idx]
  sig[,component:=meta$component[idx]]
  csig <- unique(sig[,.(component,qgram)])
  setkey(csig,qgram)
  cand <- csig[csig,allow.cartesian=TRUE,nomatch=0L][component < i.component,
    .(shared_rare_qgrams=.N),by=.(component_i=component,component_j=i.component)]
  cand <- cand[shared_rare_qgrams>=2L]
  cand[, a_app := comp$has_appended[match(component_i,comp$component)]]
  cand[, a_min := comp$min_title_len[match(component_i,comp$component)]]
  cand[, a_max := comp$max_title_len[match(component_i,comp$component)]]
  cand[, b_app := comp$has_appended[match(component_j,comp$component)]]
  cand[, b_min := comp$min_title_len[match(component_j,comp$component)]]
  cand[, b_max := comp$max_title_len[match(component_j,comp$component)]]
  cand[, max_possible_len_ratio := fifelse(
    is.na(a_min)|is.na(a_max)|is.na(b_min)|is.na(b_max), NA_real_,
    fifelse(a_max < b_min, a_max/b_min,
      fifelse(b_max < a_min, b_max/a_min, 1.0))
  )]
  cand <- cand[is.finite(max_possible_len_ratio)&max_possible_len_ratio>=0.75 & (a_app|b_app)]
  for (k in seq_len(nrow(cand))) add_pair(env,cand$component_i[[k]],cand$component_j[[k]],"rare_qgram_title")

  keys <- ls(env,all.names=TRUE)
  out <- rbindlist(lapply(keys,function(k) {
    z <- get(k,env,inherits=FALSE); data.table(component_i=z$i,component_j=z$j,blocks=paste(sort(unique(z$blocks)),collapse=";"))
  }))
  out
}

t0 <- proc.time()[["elapsed"]]
baseline <- generate_baseline()
baseline_seconds <- proc.time()[["elapsed"]] - t0
gc()
t1 <- proc.time()[["elapsed"]]
component_candidates <- generate_component()
component_seconds <- proc.time()[["elapsed"]] - t1

# Convert baseline manifestation candidates to the same component-pair space.
baseline[,component_i:=meta$component[record_i]]
baseline[,component_j:=meta$component[record_j]]
baseline[,internal_preresolved:=component_i==component_j]
base_external <- baseline[internal_preresolved==FALSE]
base_external[,component_key:=paste(pmin(component_i,component_j),pmax(component_i,component_j),sep="::")]
base_component_keys <- unique(base_external$component_key)
component_candidates[,component_key:=paste(pmin(component_i,component_j),pmax(component_i,component_j),sep="::")]
component_keys <- unique(component_candidates$component_key)

missing_component_candidates <- setdiff(base_component_keys,component_keys)
extra_component_candidates <- setdiff(component_keys,base_component_keys)

summary <- list(
  schema="living-evidence-map-w01-component-aware-candidate-benchmark-v1",
  status="success",
  test_only=TRUE,
  corpus=list(
    manifestations=nrow(meta),
    prior_manifestations=prior_n,
    appended_manifestations=nrow(meta)-prior_n,
    provisional_components=uniqueN(meta$component),
    manifestations_collapsed=nrow(meta)-uniqueN(meta$component),
    multi_manifestation_components=sum(comp$members>1L)
  ),
  baseline=list(
    manifestation_candidate_pairs=nrow(baseline),
    wall_clock_seconds=baseline_seconds
  ),
  component_aware=list(
    component_candidate_pairs=nrow(component_candidates),
    wall_clock_seconds=component_seconds,
    internal_safe_pairs_eliminated=sum(baseline$internal_preresolved),
    baseline_external_component_pairs=length(base_component_keys),
    missing_baseline_component_pairs=length(missing_component_candidates),
    extra_conservative_component_pairs=length(extra_component_candidates),
    candidate_decision_reduction_vs_manifestation_baseline=
      nrow(baseline)-nrow(component_candidates),
    candidate_decision_reduction_percent=
      100*(nrow(baseline)-nrow(component_candidates))/nrow(baseline),
    wall_clock_change_percent=
      100*(component_seconds-baseline_seconds)/baseline_seconds
  ),
  safety=list(
    baseline_component_candidate_recall=
      if (length(base_component_keys)) 1-length(missing_component_candidates)/length(base_component_keys) else 1,
    automatic_merges_performed=0L,
    production_w01_modified=FALSE
  ),
  caveat="Benchmark starts from the saved normalised metadata and measures candidate-generation/blocking only; it does not include source normalisation or downstream pair scoring."
)

if (nrow(baseline)!=503245L) stop(sprintf("Baseline mismatch: got %d expected 503245",nrow(baseline)),call.=FALSE)
if (length(missing_component_candidates)>0L) {
  fwrite(data.table(component_key=missing_component_candidates),file.path(out_dir,"ERROR_missing_component_candidates.csv"))
  stop(sprintf("Component-aware generator lost %d baseline component candidates",length(missing_component_candidates)),call.=FALSE)
}

fwrite(component_candidates,file.path(out_dir,"component_aware_candidate_pairs.csv"))
fwrite(meta[,.(idx,manifestation_key,component,appended)],file.path(out_dir,"component_membership.csv"))
fwrite(comp,file.path(out_dir,"component_summary.csv"))
fwrite(data.table(component_key=extra_component_candidates),file.path(out_dir,"extra_conservative_component_candidates.csv"))
writeLines(toJSON(summary,auto_unbox=TRUE,pretty=TRUE,null="null",na="null"),
           file.path(out_dir,"component_aware_candidate_benchmark.json"))
cat("PASS: component-aware candidate benchmark\n")
cat(toJSON(summary,auto_unbox=TRUE,pretty=TRUE,null="null",na="null"),"\n")
