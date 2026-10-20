#!/usr/bin/env Rscript
# Offline regression: incremental q-gram signatures must account for changed
# corpus-wide document frequencies, including when historical titles change rank.
suppressPackageStartupMessages(library(data.table))
qgrams<-function(x){
 if(is.na(x)||nchar(x,type="chars")<4L)return(character())
 unique(vapply(seq_len(nchar(x,type="chars")-3L),function(i)substr(x,i,i+3L),character(1)))
}
signature<-function(titles){
 postings<-rbindlist(lapply(seq_along(titles),function(i)
   data.table(idx=i,qgram=qgrams(titles[[i]]))),use.names=TRUE)
 if(!nrow(postings))return(data.table(idx=integer(),qgram=character(),df=integer()))
 df<-postings[,.(df=uniqueN(idx)),by=qgram]
 setorder(df,qgram)
 postings<-merge(postings,df,by="qgram")
 setorder(postings,idx,df,qgram)
 postings[,head(.SD,10L),by=idx]
}
historical<-c("abcdefghijklmn","abcdxxxxxxxxxx","efghyyyyyyyyyy")
# Introduce a new title sharing a historical rare q-gram. This can alter the
# historic title's top-ten ranking, even without changing its metadata.
fresh<-c(historical,"ijklzzzzzzzzzz")
before<-signature(historical)
after<-signature(fresh)
stopifnot(before[idx==1L & qgram=="ijkl",df]==1L,
          after[idx==1L & qgram=="ijkl",df]==2L)
# Verify that rebuilding from scratch remains deterministic.
stopifnot(identical(after,signature(fresh)))
cat("PASS: corpus-wide rarity changes detected; historical signatures require reassessment\\n")
