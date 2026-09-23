#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(jsonlite)
  library(stringdist)
  library(digest)
  library(xml2)
  library(stringi)
  library(data.table)
})

`%||%` <- function(x, y) if (is.null(x)) y else x

args <- commandArgs(trailingOnly = TRUE)
arg <- function(flag, default = NULL) {
  i <- match(flag, args)
  if (is.na(i)) return(default)
  if (i == length(args)) stop(sprintf("Missing value after %s", flag), call. = FALSE)
  args[[i + 1L]]
}

lens_path <- arg("--lens")
scopus_path <- arg("--scopus")
openalex_path <- arg("--openalex")
agricola_path <- arg("--agricola")
wos_path <- arg("--wos")
old_metadata_path <- arg("--old-metadata")
output_dir <- arg("--output-dir")
score_n <- as.integer(arg("--score-n", "2000"))
sample_key <- arg("--sample-key", "workflow02-v2-candidate-benchmark-v1")
workflow01_run_id <- arg("--workflow01-run-id", "unknown")
validate_index_only <- identical(tolower(arg("--validate-index-only", "false")), "true")

if (any(vapply(list(lens_path, scopus_path, openalex_path, agricola_path, wos_path, old_metadata_path, output_dir), is.null, logical(1)))) {
  stop("Required: --lens --scopus --openalex --agricola --wos --old-metadata --output-dir", call. = FALSE)
}
if (is.na(score_n) || score_n < 1L) stop("--score-n must be positive", call. = FALSE)
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

timestamp_utc <- function() format(Sys.time(), tz = "UTC", format = "%Y-%m-%dT%H:%M:%SZ")
progress <- function(stage, completed = NULL, total = NULL, extra = NULL) {
  msg <- paste0("[", timestamp_utc(), "] ", stage)
  if (!is.null(completed)) {
    msg <- paste0(msg, ": ", completed)
    if (!is.null(total)) msg <- paste0(msg, " / ", total)
  }
  if (!is.null(extra) && nzchar(extra)) msg <- paste0(msg, " | ", extra)
  cat(msg, "\n")
  flush.console()
}
checkpoint <- function(stage, completed = NULL, total = NULL, extra = list()) {
  x <- c(list(
    workflow = "02_deduplication_v2_candidate_benchmark",
    updated_at = timestamp_utc(),
    stage = stage,
    completed = completed,
    total = total
  ), extra)
  writeLines(toJSON(x, auto_unbox=TRUE, pretty=TRUE, null="null", na="null"),
             file.path(output_dir, "checkpoint_progress.json"))
}

scalar <- function(x) {
  if (is.null(x) || !length(x)) return(NULL)
  y <- as.character(x[[1L]])
  if (!nzchar(trimws(y))) NULL else y
}
strip_markup_text <- function(x) {
  x <- scalar(x)
  if (is.null(x)) return(NULL)
  wrapped <- paste0("<div>", x, "</div>")
  doc <- tryCatch(
    suppressWarnings(read_html(wrapped, options=c("RECOVER","NOERROR","NOWARNING"))),
    error=function(e) NULL
  )
  if (!is.null(doc)) {
    node <- xml_find_first(doc, ".//div")
    if (!inherits(node, "xml_missing")) x <- xml_text(node)
  }
  x
}
unicode_nfkc_lower <- function(x) {
  x <- strip_markup_text(x)
  if (is.null(x)) return(NULL)
  stri_trans_tolower(stri_trans_nfkc(x))
}
norm_title <- function(x) {
  x <- unicode_nfkc_lower(x)
  if (is.null(x)) return(NULL)
  x <- stri_replace_all_regex(x, "[\\p{P}\\p{S}\\p{Z}\\s]+", "")
  if (!nzchar(x)) NULL else x
}
norm_words <- function(x) {
  x <- unicode_nfkc_lower(x)
  if (is.null(x)) return(NULL)
  x <- stri_replace_all_regex(x, "[\\p{P}\\p{S}\\p{Z}\\s]+", " ")
  x <- trimws(stri_replace_all_regex(x, "\\s+", " "))
  if (!nzchar(x)) NULL else x
}
norm_compact <- function(x) {
  x <- unicode_nfkc_lower(x)
  if (is.null(x)) return(NULL)
  x <- stri_replace_all_regex(x, "[\\p{P}\\p{S}\\p{Z}\\s]+", "")
  if (!nzchar(x)) NULL else x
}
norm_doi <- function(x) {
  x <- scalar(x)
  if (is.null(x)) return(NULL)
  x <- tolower(trimws(x))
  x <- sub("^https?://(dx\\.)?doi\\.org/", "", x, perl=TRUE)
  x <- sub("^doi:\\s*", "", x, perl=TRUE)
  x <- sub("[?#].*$", "", x, perl=TRUE)
  x <- sub("/full/html?$", "", x, perl=TRUE, ignore.case=TRUE)
  x <- sub("\\.(html?|pdf|xml)$", "", x, perl=TRUE, ignore.case=TRUE)
  x <- sub("[.,;:]+$", "", x, perl=TRUE)
  if (!nzchar(x)) NULL else x
}
doi_family <- function(x) {
  x <- norm_doi(x)
  if (is.null(x)) return(NULL)
  sub("(/v[0-9]+|\\.v[0-9]+)$", "", x, perl=TRUE, ignore.case=TRUE)
}

author_norm <- function(x) {
  if (is.null(x) || !length(x)) return(NULL)
  one <- function(z) {
    if (is.character(z)) return(norm_compact(z))
    if (is.list(z)) {
      surname <- scalar(z$surname %||% z$last_name %||% z$family)
      given <- scalar(z$given_name %||% z$first_name %||% z$given)
      display <- scalar(z$display_name %||% z$name %||% z$full_name)
      if (!is.null(surname) || !is.null(given)) return(norm_compact(paste(surname %||% "", given %||% "")))
      return(norm_compact(display))
    }
    NULL
  }
  if (is.character(x) && length(x)==1L) x <- unlist(strsplit(x, "\\||;", perl=TRUE))
  vals <- vapply(as.list(x), function(z) one(z) %||% "", character(1))
  vals <- vals[nzchar(vals)]
  if (!length(vals)) NULL else paste(vals, collapse="|")
}

source_kind <- function(r) {
  if (is.list(r$lens)) return("lens")
  p <- scalar((r$source %||% list())$provider)
  if (identical(p,"scopus")) return("scopus")
  if (identical(p,"openalex")) return("openalex")
  if (identical(p,"agricola_via_europe_pmc")) return("agricola")
  if (identical(p,"wos_starter")) return("wos")
  stop(sprintf("Unknown source provider: %s", p %||% "<missing>"), call.=FALSE)
}
source_record_id <- function(r) {
  if (source_kind(r)=="lens") return(as.character((r$identity %||% list())$lens_id %||% (r$identity %||% list())$record_id %||% ""))
  as.character((r$sidecar_identity %||% list())$sidecar_record_id %||% "")
}
record_doi <- function(r) {
  if (source_kind(r)=="lens") {
    d <- scalar((r$canonical %||% list())$doi)
    if (!is.null(d)) return(d)
    ids <- ((r$lens %||% list())$raw_payload %||% list())$external_ids %||% list()
    for (z in ids) if (is.list(z) && identical(tolower(as.character(z$type %||% "")),"doi")) {
      d <- scalar(z$value); if (!is.null(d)) return(d)
    }
    return(NULL)
  }
  scalar((r$mapped_fields %||% list())$doi %||% (r$sidecar_identity %||% list())$doi)
}
record_title <- function(r) {
  if (source_kind(r)=="lens") return(scalar((r$canonical %||% list())$title %||% ((r$lens %||% list())$raw_payload %||% list())$title))
  scalar((r$mapped_fields %||% list())$title)
}
record_authors <- function(r) {
  if (source_kind(r)=="lens") return((r$canonical %||% list())$authors %||% ((r$lens %||% list())$raw_payload %||% list())$authors)
  (r$mapped_fields %||% list())$authors %||% (r$mapped_fields %||% list())$first_author
}
record_year <- function(r) {
  z <- if (source_kind(r)=="lens") {
    (r$canonical %||% list())$year %||% ((r$lens %||% list())$raw_payload %||% list())$year_published %||% ((r$lens %||% list())$raw_payload %||% list())$date_published
  } else (r$mapped_fields %||% list())$year %||% (r$mapped_fields %||% list())$publication_date
  s <- as.character(z %||% "")
  m <- regexpr("(19|20)[0-9]{2}", s, perl=TRUE)
  if (m[[1L]]<0L) NA_integer_ else as.integer(regmatches(s,m)[[1L]])
}
record_journal <- function(r) {
  if (source_kind(r)=="lens") {
    s <- (r$canonical %||% list())$source %||% ((r$lens %||% list())$raw_payload %||% list())$source
    if (is.list(s)) return(scalar(s$title))
    return(scalar(s))
  }
  scalar((r$mapped_fields %||% list())$source %||% (r$mapped_fields %||% list())$journal)
}
record_volume <- function(r) {
  if (source_kind(r)=="lens") return(scalar((r$canonical %||% list())$volume %||% ((r$lens %||% list())$raw_payload %||% list())$volume))
  scalar((r$mapped_fields %||% list())$volume)
}
record_issue <- function(r) {
  if (source_kind(r)=="lens") return(scalar((r$canonical %||% list())$issue %||% ((r$lens %||% list())$raw_payload %||% list())$issue))
  scalar((r$mapped_fields %||% list())$issue)
}
record_pages <- function(r) {
  if (source_kind(r)=="lens") return(scalar((r$canonical %||% list())$pages %||% ((r$lens %||% list())$raw_payload %||% list())$pages))
  scalar((r$mapped_fields %||% list())$pages %||% (r$mapped_fields %||% list())$article_number)
}
record_abstract <- function(r) {
  if (source_kind(r)=="lens") return(scalar((r$canonical %||% list())$abstract %||% ((r$lens %||% list())$raw_payload %||% list())$abstract))
  scalar((r$mapped_fields %||% list())$abstract)
}
read_jsonl <- function(path, fun) {
  con <- file(path,"rt",encoding="UTF-8")
  on.exit(close(con),add=TRUE)
  i <- 0L
  repeat {
    lines <- readLines(con,n=500L,warn=FALSE)
    if (!length(lines)) break
    for (line in lines) {
      if (!nzchar(trimws(line))) next
      i <- i+1L
      fun(fromJSON(line,simplifyVector=FALSE),i)
    }
  }
  i
}

progress("reading and normalising all source records")
paths <- c(lens=lens_path,scopus=scopus_path,openalex=openalex_path,agricola=agricola_path,wos=wos_path)
rows <- list(); n_by_source <- integer()
for (src in names(paths)) {
  n_by_source[[src]] <- read_jsonl(paths[[src]], function(r,i) {
    rid <- source_record_id(r)
    if (!nzchar(rid)) stop(sprintf("%s record %d lacks source ID",src,i),call.=FALSE)
    ttl <- record_title(r); abs <- record_abstract(r); d <- record_doi(r)
    rows[[length(rows)+1L]] <<- data.table(
      idx=length(rows)+1L, source=src, source_record_id=rid,
      title=ttl %||% NA_character_, title_norm=norm_title(ttl) %||% NA_character_,
      doi_norm=norm_doi(d) %||% NA_character_, doi_family=doi_family(d) %||% NA_character_,
      abstract_norm=norm_words(abs) %||% NA_character_,
      abstract_hash=if (is.null(norm_words(abs))) NA_character_ else digest(norm_words(abs),algo="sha256",serialize=FALSE),
      author_norm=author_norm(record_authors(r)) %||% NA_character_,
      year=record_year(r),
      journal_norm=norm_compact(record_journal(r)) %||% NA_character_,
      volume_norm=norm_compact(record_volume(r)) %||% NA_character_,
      issue_norm=norm_compact(record_issue(r)) %||% NA_character_,
      pages_norm=norm_compact(record_pages(r)) %||% NA_character_
    )
  })
  progress("source normalisation complete", n_by_source[[src]], n_by_source[[src]], src)
  checkpoint(paste0("normalised_",src),sum(n_by_source),NULL,list(source_counts=as.list(n_by_source)))
}
meta <- rbindlist(rows,use.names=TRUE,fill=TRUE)
meta[, corpus_key := paste(source,source_record_id,sep="::")]
if (anyDuplicated(meta$corpus_key)) stop("Duplicate source namespace + record ID",call.=FALSE)

# Provenance-critical incremental indexing:
# retain the exact historical source/source_record_id row order, but use the
# freshly normalised metadata values for those manifestations. Append only
# manifestations absent from the historical corpus, in deterministic current
# source order. Historic pair decisions therefore continue to address the same
# manifestation indices without blocking legitimate metadata repairs.
old_meta <- fread(old_metadata_path, na.strings=c("", "NA"))
stopifnot(all(c("source","source_record_id") %in% names(old_meta)))
old_keys <- paste(old_meta$source,old_meta$source_record_id,sep="::")
if (anyDuplicated(old_keys)) stop("Historical metadata contains duplicate source namespace + record ID",call.=FALSE)

old_pos <- match(old_keys,meta$corpus_key)
if (anyNA(old_pos)) {
  missing_prior <- old_keys[is.na(old_pos)]
  writeLines(missing_prior,file.path(output_dir,"ERROR_prior_manifestations_missing_from_union.txt"))
  stop(sprintf("Union input is missing %d prior-corpus manifestations",length(missing_prior)),call.=FALSE)
}
new_pos <- which(!(meta$corpus_key %in% old_keys))
meta <- rbindlist(list(meta[old_pos],meta[new_pos]),use.names=TRUE,fill=TRUE)
meta[, idx := seq_len(.N)]
meta[, corpus_key := NULL]

stopifnot(identical(as.character(meta$source[seq_along(old_keys)]),as.character(old_meta$source)))
stopifnot(identical(as.character(meta$source_record_id[seq_along(old_keys)]),as.character(old_meta$source_record_id)))

fwrite(meta[,.(idx,source,source_record_id,title,title_norm,doi_norm,doi_family,abstract_hash,author_norm,year,journal_norm,volume_norm,issue_norm,pages_norm)],
       file.path(output_dir,"normalised_metadata.csv"))
progress("normalisation complete",nrow(meta),nrow(meta),
         sprintf("historical prefix preserved=%d appended=%d",length(old_keys),length(new_pos)))
checkpoint("normalisation_complete",nrow(meta),nrow(meta),
           list(source_counts=as.list(n_by_source),historical_prefix_preserved=length(old_keys),appended_manifestations=length(new_pos)))

if (validate_index_only) {
  cat(sprintf("PASS: metadata-only validation complete: %d historical rows preserved, %d appended manifestations\n",
              length(old_keys), length(new_pos)))
  quit(save="no", status=0L)
}

pairs <- new.env(hash=TRUE,parent=emptyenv())
add_pairs_from_groups <- function(dt,key_col,block,max_group=500L) {
  x <- dt[!is.na(get(key_col)) & nzchar(get(key_col)),.(idx,key=get(key_col))]
  g <- x[,.N,by=key][N>1L & N<=max_group]
  if (!nrow(g)) return(list(groups=0L,pairs_added=0L,skipped=x[,.N,by=key][N>max_group,.N]))
  x <- x[g,on="key",nomatch=0L]
  added <- 0L
  split_idx <- split(x$idx,x$key)
  for (v in split_idx) {
    if (length(v)<2L) next
    cmb <- combn(v,2L)
    for (j in seq_len(ncol(cmb))) {
      a <- min(cmb[1L,j],cmb[2L,j]); b <- max(cmb[1L,j],cmb[2L,j])
      k <- paste(a,b,sep="::")
      if (!exists(k,pairs,inherits=FALSE)) assign(k,list(i=a,j=b,blocks=block),pairs)
      else {
        z <- get(k,pairs,inherits=FALSE); z$blocks <- unique(c(z$blocks,block)); assign(k,z,pairs)
      }
      added <- added+1L
    }
  }
  list(groups=length(split_idx),pairs_added=added,skipped=x[,.N,by=key][N>max_group,.N])
}
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

block_names <- c("bramer_A","bramer_B","bramer_C","bramer_D","bramer_E","bramer_F","bramer_G","doi_norm","doi_family","abstract_hash")
block_stats <- list()
for (bn in block_names) {
  progress(paste("exact candidate block",bn,"started"))
  block_stats[[bn]] <- add_pairs_from_groups(meta,bn,bn)
  progress(paste("exact candidate block",bn,"complete"),length(ls(pairs,all.names=TRUE)),NULL)
  checkpoint(paste0("candidate_block_",bn,"_complete"),length(ls(pairs,all.names=TRUE)),NULL,list(block=bn,block_stats=block_stats[[bn]]))
}

# Efficient fuzzy-title candidate discovery.
# Build all 4-character Unicode q-grams once, compute corpus document frequency,
# and retain each title's 10 rarest q-grams. Candidate pairs must share >=2 retained
# q-grams and have a title-length ratio >=0.75. This is candidate discovery only;
# final duplicate rules/thresholds are unchanged.
progress("building full-corpus rare q-gram title index")
qgram_rows <- vector("list",nrow(meta))
for (i in seq_len(nrow(meta))) {
  s <- meta$title_norm[[i]]
  if (is.na(s) || nchar(s,type="chars")<4L) next
  n <- nchar(s,type="chars")
  qs <- unique(vapply(seq_len(n-3L),function(k) substr(s,k,k+3L),character(1)))
  qgram_rows[[i]] <- data.table(idx=i,qgram=qs)
  if (i %% 5000L==0L) {
    progress("q-gram extraction",i,nrow(meta))
    checkpoint("qgram_extraction",i,nrow(meta))
  }
}
qdt <- rbindlist(qgram_rows,use.names=TRUE,fill=TRUE)
qfreq <- qdt[,.(df=uniqueN(idx)),by=qgram]
setkey(qfreq,qgram)
qdt <- qfreq[qdt,on="qgram"]
setorder(qdt,idx,df,qgram)
sig <- qdt[,head(.SD,10L),by=idx]
fwrite(sig,file.path(output_dir,"title_qgram_signatures.csv"))
progress("rare q-gram signatures built",nrow(sig),nrow(sig),paste("titles:",uniqueN(sig$idx)))
checkpoint("qgram_signatures_complete",uniqueN(sig$idx),nrow(meta),list(signature_rows=nrow(sig)))

# Self-join by q-gram, count shared retained signatures.
setkey(sig,qgram)
cand <- sig[sig,allow.cartesian=TRUE,nomatch=0L][idx < i.idx,
  .(shared_rare_qgrams=.N),by=.(record_i=idx,record_j=i.idx)]
cand <- cand[shared_rare_qgrams>=2L]
title_len <- nchar(meta$title_norm,type="chars")
cand[,len_ratio:=pmin(title_len[record_i],title_len[record_j])/pmax(title_len[record_i],title_len[record_j])]
cand <- cand[is.finite(len_ratio) & len_ratio>=0.75]
progress("rare q-gram candidate join complete",nrow(cand),nrow(cand))
checkpoint("qgram_candidate_join_complete",nrow(cand),NULL,list(candidate_pairs=nrow(cand)))

for (k in seq_len(nrow(cand))) {
  a <- cand$record_i[[k]]; b <- cand$record_j[[k]]
  key <- paste(a,b,sep="::")
  if (!exists(key,pairs,inherits=FALSE)) assign(key,list(i=a,j=b,blocks="rare_qgram_title"),pairs)
  else {
    z <- get(key,pairs,inherits=FALSE); z$blocks <- unique(c(z$blocks,"rare_qgram_title")); assign(key,z,pairs)
  }
  if (k %% 5000L==0L) progress("q-gram candidates added",k,nrow(cand))
}
rm(qgram_rows,qdt,qfreq,sig,cand); gc()
pair_keys <- ls(pairs,all.names=TRUE)
progress("full-corpus candidate generation complete",length(pair_keys),length(pair_keys))
checkpoint("candidate_generation_complete",length(pair_keys),length(pair_keys),list(total_candidate_pairs=length(pair_keys)))

# Materialise lightweight candidate table before any expensive scoring.
light <- vector("list",length(pair_keys))
for (k in seq_along(pair_keys)) {
  z <- get(pair_keys[[k]],pairs,inherits=FALSE)
  light[[k]] <- data.table(record_i=z$i,record_j=z$j,blocks=paste(sort(unique(z$blocks)),collapse=";"))
}
candidate_dt <- rbindlist(light)

# Incremental extension: preserve every decision from the prior 72,941-manifestation
# corpus. Only candidate pairs involving at least one manifestation absent from the
# prior normalised metadata are retained for scoring.
meta[, prior_corpus := idx <= length(old_keys)]
matched_prior <- sum(meta$prior_corpus)
new_n <- sum(!meta$prior_corpus)
if (matched_prior != length(old_keys)) stop("Prior-corpus cardinality mismatch", call.=FALSE)

candidate_dt[, prior_i := meta$prior_corpus[record_i]]
candidate_dt[, prior_j := meta$prior_corpus[record_j]]
full_candidate_n <- nrow(candidate_dt)
candidate_dt <- candidate_dt[!(prior_i & prior_j)]
candidate_dt[, c("prior_i","prior_j") := NULL]

fwrite(candidate_dt,file.path(output_dir,"all_candidate_pairs.csv"))
fwrite(meta[,.(idx,source,source_record_id,prior_corpus)],
       file.path(output_dir,"incremental_manifestation_inventory.csv"))
writeLines(toJSON(list(
  workflow="01_deduplication_incremental_candidate_extension",
  prior_manifestations=matched_prior,
  appended_manifestations=new_n,
  union_manifestations=nrow(meta),
  full_candidate_pairs_before_prior_filter=full_candidate_n,
  incremental_candidate_pairs=nrow(candidate_dt),
  old_old_pairs_excluded=full_candidate_n-nrow(candidate_dt)
), auto_unbox=TRUE, pretty=TRUE),
file.path(output_dir,"incremental_summary.json"))

progress("incremental candidate artefact written",nrow(candidate_dt),nrow(candidate_dt),
         sprintf("prior=%d appended=%d old-old excluded=%d",matched_prior,new_n,full_candidate_n-nrow(candidate_dt)))
checkpoint("candidate_artifact_written",nrow(candidate_dt),nrow(candidate_dt),
           list(prior_manifestations=matched_prior,appended_manifestations=new_n,
                old_old_pairs_excluded=full_candidate_n-nrow(candidate_dt)))

# Deterministic stratified scoring sample.
candidate_dt[,primary_block:=tstrsplit(blocks,";",fixed=TRUE,keep=1L)]
candidate_dt[,sample_hash:=vapply(seq_len(.N),function(i)
  digest(paste(sample_key,record_i[[i]],record_j[[i]],sep="|"),algo="sha256",serialize=FALSE),character(1))]
setorder(candidate_dt,primary_block,sample_hash)
nb <- uniqueN(candidate_dt$primary_block)
per_block <- max(20L,ceiling(score_n/max(1L,nb)))
score_sample <- candidate_dt[,head(.SD,per_block),by=primary_block]
if (nrow(score_sample)>score_n) {
  setorder(score_sample,sample_hash)
  score_sample <- score_sample[seq_len(score_n)]
}
fwrite(score_sample,file.path(output_dir,"scoring_sample.csv"))
progress("stratified scoring sample selected",nrow(score_sample),score_n)
checkpoint("scoring_sample_selected",nrow(score_sample),score_n)

tokens <- function(x) if (is.na(x)||!nzchar(x)) character() else strsplit(x," ",fixed=TRUE)[[1L]]
shingles5 <- function(t) if (length(t)<5L) character() else unique(vapply(seq_len(length(t)-4L),function(i)paste(t[i:(i+4L)],collapse=" "),character(1)))
lcs_len <- function(a,b) {
  if (!length(a)||!length(b)) return(0L)
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
  strong <- (l>=80L && oc>=0.90 && !is.na(sh)&&sh>=0.60) || (l>=60L&&l<=79L&&oc>=0.95&&!is.na(sh)&&sh>=0.75)
  list(lcs=l,ordered=oc,shingle=sh,strong=strong)
}

scored <- vector("list",nrow(score_sample))
for (k in seq_len(nrow(score_sample))) {
  if (k==1L || k%%100L==0L || k==nrow(score_sample)) {
    progress("scoring benchmark pairs",k,nrow(score_sample))
    checkpoint("scoring_pairs",k,nrow(score_sample))
  }
  i<-score_sample$record_i[[k]];j<-score_sample$record_j[[k]]
  a<-meta[i];b<-meta[j]
  same_doi <- !is.na(a$doi_norm)&&!is.na(b$doi_norm)&&identical(a$doi_norm,b$doi_norm)
  same_family <- !is.na(a$doi_family)&&!is.na(b$doi_family)&&identical(a$doi_family,b$doi_family)
  diff_doi <- !is.na(a$doi_norm)&&!is.na(b$doi_norm)&&!identical(a$doi_norm,b$doi_norm)
  exact_title <- !is.na(a$title_norm)&&!is.na(b$title_norm)&&identical(a$title_norm,b$title_norm)
  tsim <- if (!is.na(a$title_norm)&&!is.na(b$title_norm)) as.numeric(stringsim(a$title_norm,b$title_norm,method="jw",p=0.1)) else NA_real_
  containment <- FALSE
  if (!is.na(a$title_norm)&&!is.na(b$title_norm)) {
    short<-if(nchar(a$title_norm)<=nchar(b$title_norm))a$title_norm else b$title_norm
    long<-if(nchar(a$title_norm)<=nchar(b$title_norm))b$title_norm else a$title_norm
    containment<-nchar(short)>=30L&&grepl(short,long,fixed=TRUE)
  }
  exact_abs <- !is.na(a$abstract_hash)&&!is.na(b$abstract_hash)&&identical(a$abstract_hash,b$abstract_hash)
  exact_author <- !is.na(a$author_norm)&&!is.na(b$author_norm)&&identical(a$author_norm,b$author_norm)
  exact_year <- !is.na(a$year)&&!is.na(b$year)&&identical(a$year,b$year)
  yd <- if (!is.na(a$year)&&!is.na(b$year)) abs(a$year-b$year) else NA_integer_
  blocks<-score_sample$blocks[[k]]
  brA<-grepl("(^|;)bramer_A(;|$)",blocks)
  brB<-grepl("(^|;)bramer_B(;|$)",blocks)
  need_abs <- !exact_abs && !is.na(tsim) && (tsim>=0.90||containment||exact_title)
  am <- if (need_abs && !is.na(a$abstract_norm)&&!is.na(b$abstract_norm)) abstract_metrics(a$abstract_norm,b$abstract_norm) else list(lcs=NA_integer_,ordered=NA_real_,shingle=NA_real_,strong=FALSE)

  auto<-NULL
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

  cls<-"unresolved";rule<-"candidate_only"
  if(!is.null(auto)) {
    if(diff_doi&&!same_family&&!grepl("^exact_doi_",auto)){cls<-"review";rule<-"material_conflict_different_doi"}
    else{cls<-"duplicate";rule<-auto}
  } else if(exact_abs){cls<-"review";rule<-"exact_abstract_insufficient_metadata"}
  else if(same_family&&diff_doi&&!is.na(tsim)&&tsim>=0.97){cls<-"review";rule<-"doi_family_title_similarity_0.97"}
  else if(exact_title&&!is.na(yd)&&yd<=1L){cls<-"review";rule<-"exact_title_year_within_1"}
  else if(am$strong&&diff_doi&&!same_family){cls<-"review";rule<-"strong_content_material_doi_conflict"}

  scored[[k]]<-data.table(
    record_i=i,record_j=j,source_i=a$source,source_j=b$source,
    title_i=a$title,title_j=b$title,doi_i=a$doi_norm,doi_j=b$doi_norm,
    blocks=blocks,title_similarity=tsim,title_containment=containment,
    exact_title=exact_title,exact_abstract=exact_abs,
    ordered_coverage=am$ordered,shingle_containment=am$shingle,lcs_tokens=am$lcs,
    classification=cls,rule=rule
  )
}
scored_dt<-rbindlist(scored,fill=TRUE)
fwrite(scored_dt,file.path(output_dir,"scored_sample.csv"))

summary<-list(
  workflow="02_deduplication_v2_candidate_benchmark",
  status="success",
  workflow01_run_id=workflow01_run_id,
  sample_key=sample_key,
  total_source_manifestations=nrow(meta),
  source_counts=as.list(n_by_source),
  total_candidate_pairs=nrow(candidate_dt),
  scoring_sample_n=nrow(scored_dt),
  scoring_classification_counts=as.list(table(scored_dt$classification)),
  scoring_rule_counts=as.list(table(scored_dt$rule)),
  block_stats=block_stats,
  historic_human_adjudications_loaded=FALSE,
  clustering_performed=FALSE,
  safeguards=list(source_payloads_modified=FALSE,canonical_modified=FALSE)
)
writeLines(toJSON(summary,auto_unbox=TRUE,pretty=TRUE,null="null",na="null"),file.path(output_dir,"summary.json"))
progress("benchmark complete",nrow(scored_dt),nrow(scored_dt),paste("full candidate pairs:",nrow(candidate_dt)))
checkpoint("complete",nrow(scored_dt),nrow(scored_dt),list(status="success",total_candidate_pairs=nrow(candidate_dt)))
cat(toJSON(summary,auto_unbox=TRUE,pretty=TRUE,null="null",na="null"),"\n")
