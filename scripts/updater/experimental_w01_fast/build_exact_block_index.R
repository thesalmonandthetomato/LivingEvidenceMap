#!/usr/bin/env Rscript
# Experimental read-only W01 incremental index. Never writes canonical or production state.
suppressPackageStartupMessages({library(data.table);library(jsonlite);library(digest)})
args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag) {i <- match(flag,args); if(is.na(i)||i==length(args)) stop(paste("Missing",flag)); args[[i+1L]]}
input <- arg("--metadata"); prior_n <- as.integer(arg("--prior-n")); out <- arg("--output-dir")
m <- fread(input,na.strings=c("","NA"))
required <- c("idx","source","source_record_id","title_norm","doi_norm","doi_family","abstract_hash",
              "author_norm","year","journal_norm","volume_norm","issue_norm","pages_norm")
stopifnot(all(required %in% names(m)),identical(as.integer(m$idx),seq_len(nrow(m))),
          length(prior_n)==1L,!is.na(prior_n),prior_n>=0L,prior_n<=nrow(m))
key_complete <- function(...) {
  xs <- list(...); n <- length(xs[[1L]]); out <- rep(NA_character_,n); ok <- rep(TRUE,n)
  for(x in xs) ok <- ok & !is.na(x) & nzchar(as.character(x))
  if(any(ok)) out[ok] <- do.call(paste,c(lapply(xs,function(x)x[ok]),sep="::"))
  out
}
m[,bramer_A:=key_complete(author_norm,year,title_norm,journal_norm)]
m[,bramer_B:=key_complete(author_norm,year,title_norm,pages_norm)]
m[,bramer_C:=key_complete(title_norm,volume_norm,pages_norm)]
m[,bramer_D:=key_complete(author_norm,volume_norm,pages_norm)]
m[,bramer_E:=key_complete(year,volume_norm,issue_norm,pages_norm)]
m[,bramer_F:=title_norm]
m[,bramer_G:=key_complete(author_norm,year)]
blocks <- c("bramer_A","bramer_B","bramer_C","bramer_D","bramer_E","bramer_F","bramer_G","doi_norm","doi_family","abstract_hash")
dir.create(out,recursive=TRUE,showWarnings=FALSE)
# Save compact lookup postings, keyed by value; no copying historical pair decisions.
postings <- rbindlist(lapply(blocks,function(b) {
  p <- m[seq_len(prior_n),.(idx,key=get(b))]
  p <- p[!is.na(key)&nzchar(key)]
  p[,block:=b]
  p
}),use.names=TRUE)
setcolorder(postings,c("block","key","idx"));setkey(postings,block,key)
saveRDS(postings,file.path(out,"historical_postings.rds"),compress="xz")
# Generate only new-to-historical and new-to-new exact-block candidates.
new <- if(prior_n<nrow(m)) m[seq.int(prior_n+1L,nrow(m)),] else m[0L,]
pair_chunks <- vector("list",length(blocks))
for(k in seq_along(blocks)){
  b <- blocks[[k]]
  old <- postings[block==b,.(key,old_idx=idx)]
  now <- new[,.(key=get(b),new_idx=idx)][!is.na(key)&nzchar(key)]
  # Mirror production's maximum group size of 500 across historical + new.
  freq <- rbindlist(list(old[,.(key)],now[,.(key)]))[, .N,by=key][N>1L & N<=500L,.(key)]
  old <- old[freq,on="key",nomatch=0L]
  now <- now[freq,on="key",nomatch=0L]
  oh <- merge(now,old,by="key",allow.cartesian=TRUE)[,.(record_i=old_idx,record_j=new_idx)]
  nn <- merge(now,now,by="key",allow.cartesian=TRUE)[new_idx.x<new_idx.y,
         .(record_i=new_idx.x,record_j=new_idx.y)]
  pair_chunks[[k]] <- rbindlist(list(oh,nn))[,block:=b]
}
pairs <- rbindlist(pair_chunks,use.names=TRUE)
if(nrow(pairs)){
  pairs <- pairs[,.(blocks=paste(sort(unique(block)),collapse=";")),by=.(record_i,record_j)]
  setorder(pairs,record_i,record_j)
}
fwrite(pairs,file.path(out,"exact_block_candidates.csv"))
manifest <- list(schema="experimental-w01-fast-exact-block-v1",historical_manifestations=prior_n,
                 new_manifestations=nrow(m)-prior_n,exact_block_candidate_pairs=nrow(pairs),
                 input_sha256=digest(file=input,algo="sha256",serialize=FALSE),
                 production_publication_allowed=FALSE,includes_fuzzy_qgram_candidates=FALSE,
                 includes_identifier_assist=FALSE,includes_cluster_updates=FALSE)
writeLines(toJSON(manifest,auto_unbox=TRUE,pretty=TRUE),file.path(out,"manifest.json"))
cat(sprintf("EXPERIMENTAL W01 INDEX: historical=%d new=%d exact-block pairs=%d; NO production writes\n",
            prior_n,nrow(m)-prior_n,nrow(pairs)))
