#!/usr/bin/env Rscript
# Experimental fuzzy candidates from persisted q-gram postings and current rarity.
# Matches the reference builder's top-ten q-gram selection and pair filters.
suppressPackageStartupMessages(library(data.table))
a<-commandArgs(trailingOnly=TRUE)
arg<-function(k){i<-match(k,a);if(is.na(i)||i==length(a))stop(paste("Missing",k));a[[i+1L]]}
state<-readRDS(arg("--state"));out<-arg("--output");prior_n<-as.integer(arg("--prior-n"))
stopifnot(identical(state$schema,"w01-fast-qgram-postings-v1"),
 length(prior_n)==1L,!is.na(prior_n),prior_n>=0L,prior_n<=nrow(state$history))
p<-copy(state$postings);f<-copy(state$frequency)
if(nrow(p)){
 p<-merge(p,f,by="qgram",all.x=TRUE,sort=FALSE)
 setorder(p,idx,df,qgram)
 sig<-p[,head(.SD,10L),by=idx]
 old<-sig[idx<=prior_n,.(idx,qgram)]
 new<-sig[idx>prior_n,.(idx,qgram)]
 oh<-merge(old,new,by="qgram",allow.cartesian=TRUE)[,
   .(shared_rare_qgrams=.N),by=.(record_i=idx.x,record_j=idx.y)]
 nn<-merge(new,new,by="qgram",allow.cartesian=TRUE)[idx.x<idx.y,
   .(shared_rare_qgrams=.N),by=.(record_i=idx.x,record_j=idx.y)]
 cand<-rbindlist(list(oh,nn))[shared_rare_qgrams>=2L]
 if(nrow(cand)){
  lengths<-nchar(state$history$title_norm,type="chars")
  cand[,len_ratio:=pmin(lengths[record_i],lengths[record_j])/
    pmax(lengths[record_i],lengths[record_j])]
  cand<-cand[is.finite(len_ratio)&len_ratio>=0.75]
  setorder(cand,record_i,record_j)
 }else cand<-data.table(record_i=integer(),record_j=integer(),
    shared_rare_qgrams=integer(),len_ratio=numeric())
}else cand<-data.table(record_i=integer(),record_j=integer(),
    shared_rare_qgrams=integer(),len_ratio=numeric())
if(file.exists(out))stop("Refusing to overwrite candidate file")
dir.create(dirname(out),recursive=TRUE,showWarnings=FALSE)
fwrite(cand,out)
cat(sprintf("PASS: %d incremental fuzzy candidates from persisted postings\n",nrow(cand)))
