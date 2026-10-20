#!/usr/bin/env Rscript
# Experimental incremental q-gram document frequencies. Local files only.
# Recomputes frequencies for new titles, including historical q-grams, without
# rebuilding the historical title-to-q-gram postings from raw titles.
suppressPackageStartupMessages({library(data.table);library(digest)})
a<-commandArgs(trailingOnly=TRUE)
arg<-function(k){i<-match(k,a);if(is.na(i)||i==length(a))stop(paste("Missing",k));a[[i+1L]]}
mode<-arg("--mode");metadata<-arg("--metadata");output<-arg("--output")
if(!mode%in%c("init","append"))stop("Invalid mode")
state_file<-if(mode=="append")arg("--state")else NULL
m<-fread(metadata,na.strings=c("","NA"))
stopifnot(all(c("idx","source","source_record_id","title_norm")%in%names(m)),
 identical(as.integer(m$idx),seq_len(nrow(m))),
 !anyDuplicated(paste(m$source,m$source_record_id,sep="::")))
grams<-function(x){
 if(is.na(x)||nchar(x,type="chars")<4L)return(character())
 unique(vapply(seq_len(nchar(x,type="chars")-3L),function(k)
   substr(x,k,k+3L),character(1)))
}
postings<-function(x){
 chunks<-lapply(seq_len(nrow(x)),function(i)
   data.table(idx=x$idx[[i]],qgram=grams(x$title_norm[[i]])))
 z<-rbindlist(chunks)
 if(!nrow(z))z<-data.table(idx=integer(),qgram=character())
 z
}
if(mode=="init"){
 previous<-data.table(idx=integer(),qgram=character())
 n_old<-0L
}else{
 state<-readRDS(state_file)
 stopifnot(identical(state$schema,"w01-fast-qgram-postings-v1"))
 n_old<-nrow(state$history)
 if(nrow(m)<n_old)stop("Historical record count decreased")
 fields<-c("source","source_record_id","title_norm")
 for(field in fields)
   if(!identical(as.character(m[[field]][seq_len(n_old)]),
                 as.character(state$history[[field]])))
     stop(paste("Historical",field,"changed; rebuild required"))
 previous<-state$postings
}
new<-if(n_old<nrow(m))m[seq.int(n_old+1L,nrow(m))]else m[0L]
additional<-postings(new)
all<-rbindlist(list(previous,additional))
freq<-all[,.(df=uniqueN(idx)),by=qgram]
setkey(freq,qgram)
affected<-unique(previous[qgram%in%additional$qgram,idx])
# These historical titles' top-ten signatures must be revisited on append.
state<-list(schema="w01-fast-qgram-postings-v1",
 history=m[,.(source,source_record_id,title_norm)],
 postings=all,frequency=freq,production_publication_allowed=FALSE)
if(file.exists(output))stop("Refusing to overwrite output")
dir.create(dirname(output),recursive=TRUE,showWarnings=FALSE)
saveRDS(state,output,compress="xz")
cat(sprintf("PASS: %d old, %d new titles; %d q-grams; %d affected historical titles\n",
 n_old,nrow(new),nrow(freq),length(affected)))
