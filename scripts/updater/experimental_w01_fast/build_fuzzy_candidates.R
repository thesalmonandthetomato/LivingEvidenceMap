#!/usr/bin/env Rscript
# Experimental W01-Fast fuzzy candidate lookup. Read-only, no production outputs.
suppressPackageStartupMessages({library(data.table);library(jsonlite);library(digest)})
args <- commandArgs(trailingOnly=TRUE)
arg <- function(x) {p<-match(x,args);if(is.na(p)||p==length(args))stop(paste("Missing",x));args[[p+1L]]}
p<-arg("--metadata");prior_n<-as.integer(arg("--prior-n"));out<-arg("--output-dir")
m<-fread(p,na.strings=c("","NA"))
stopifnot(all(c("idx","title_norm") %in% names(m)),identical(as.integer(m$idx),seq_len(nrow(m))),
          length(prior_n)==1L,!is.na(prior_n),prior_n>=0L,prior_n<=nrow(m))
dir.create(out,recursive=TRUE,showWarnings=FALSE)
# Exact semantic parity with production: 4-character Unicode q-grams, full-corpus
# document frequencies, 10 rarest per title, two shared signatures, length >= .75.
parts<-vector("list",nrow(m))
for(i in seq_len(nrow(m))){
  s<-m$title_norm[[i]]
  if(is.na(s)||nchar(s,type="chars")<4L) next
  qs<-unique(vapply(seq_len(nchar(s,type="chars")-3L),
                     function(k)substr(s,k,k+3L),character(1)))
  parts[[i]]<-data.table(idx=i,qgram=qs)
}
qdt<-rbindlist(parts,use.names=TRUE,fill=TRUE)
if(nrow(qdt)){
  freq<-qdt[,.(df=uniqueN(idx)),by=qgram]
  setkey(freq,qgram)
  qdt<-freq[qdt,on="qgram"]
  setorder(qdt,idx,df,qgram)
  sig<-qdt[,head(.SD,10L),by=idx]
} else sig<-data.table(idx=integer(),qgram=character(),df=integer())
# Save the versioned index for subsequent experimentation; matching is still
# evaluated using current full-corpus rarity, not presumed invariant history.
saveRDS(sig,file.path(out,"qgram_signatures.rds"),compress="xz")
if(nrow(sig)){
  setkey(sig,qgram)
  old<-sig[idx<=prior_n,.(idx,qgram)]
  new<-sig[idx>prior_n,.(idx,qgram)]
  old_new<-merge(old,new,by="qgram",allow.cartesian=TRUE)[,
    .(shared_rare_qgrams=.N),by=.(record_i=idx.x,record_j=idx.y)]
  new_new<-merge(new,new,by="qgram",allow.cartesian=TRUE)[idx.x<idx.y,
    .(shared_rare_qgrams=.N),by=.(record_i=idx.x,record_j=idx.y)]
  cand<-rbindlist(list(old_new,new_new))
  cand<-cand[shared_rare_qgrams>=2L]
  lens<-nchar(m$title_norm,type="chars")
  cand[,len_ratio:=pmin(lens[record_i],lens[record_j])/pmax(lens[record_i],lens[record_j])]
  cand<-cand[is.finite(len_ratio)&len_ratio>=0.75]
  setorder(cand,record_i,record_j)
} else cand<-data.table(record_i=integer(),record_j=integer(),shared_rare_qgrams=integer(),len_ratio=numeric())
fwrite(cand,file.path(out,"fuzzy_candidates.csv"))
writeLines(toJSON(list(schema="experimental-w01-fast-fuzzy-v1",prior_manifestations=prior_n,
 new_manifestations=nrow(m)-prior_n,fuzzy_candidate_pairs=nrow(cand),
 input_sha256=digest(file=p,algo="sha256",serialize=FALSE),
 full_corpus_rarity_recomputed=TRUE,production_publication_allowed=FALSE),
 auto_unbox=TRUE,pretty=TRUE),file.path(out,"manifest.json"))
cat(sprintf("EXPERIMENTAL W01 fuzzy: %d pairs; production untouched\\n",nrow(cand)))
