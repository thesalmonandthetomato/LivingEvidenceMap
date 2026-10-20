#!/usr/bin/env Rscript
suppressPackageStartupMessages(library(data.table))
root<-tempfile("qgram-");dir.create(root)
script<-"scripts/updater/experimental_w01_fast/persistent_qgram_frequency.R"
run<-function(args,ok=TRUE){
 x<-suppressWarnings(system2(file.path(R.home("bin"),"Rscript"),
    c(script,args),stdout=TRUE,stderr=TRUE))
 code<-attr(x,"status");if(is.null(code))code<-0L
 if((code==0L)!=ok)stop(paste("Unexpected result:",paste(x,collapse=" | ")))
}
m<-data.table(idx=1:3,source="a",source_record_id=c("A","B","C"),
 title_norm=c("abcdefghijklmn","abcdxxxxxxxxxx","efghyyyyyyyyyy"))
one<-file.path(root,"one.csv");fwrite(m[1:2],one)
state1<-file.path(root,"first.rds")
run(c("--mode","init","--metadata",one,"--output",state1))
two<-file.path(root,"two.csv");fwrite(m,two)
state2<-file.path(root,"second.rds")
run(c("--mode","append","--metadata",two,"--state",state1,"--output",state2))
x<-readRDS(state2)
stopifnot(x$frequency[qgram=="abcd",df]==2L)
# Add another record with an existing old rare q-gram.
m4<-rbind(m,data.table(idx=4L,source="a",source_record_id="D",
 title_norm="ijklzzzzzzzzzz"))
three<-file.path(root,"three.csv");fwrite(m4,three)
state3<-file.path(root,"third.rds")
run(c("--mode","append","--metadata",three,"--state",state2,"--output",state3))
y<-readRDS(state3)
stopifnot(y$frequency[qgram=="ijkl",df]==2L,
          y$frequency[qgram=="abcd",df]==2L)
# Compare all document frequencies against independent full-corpus counts.
gr<-function(z)if(is.na(z)||nchar(z)<4L)character()else
 unique(vapply(seq_len(nchar(z)-3L),function(i)substr(z,i,i+3L),character(1)))
all<-rbindlist(lapply(seq_len(nrow(m4)),function(i)
 data.table(idx=i,qgram=gr(m4$title_norm[[i]]))))
reference<-all[,.(df=uniqueN(idx)),by=qgram]
setorder(reference,qgram)
actual<-copy(y$frequency);setorder(actual,qgram)
setcolorder(actual,names(reference))
stopifnot(identical(as.data.frame(reference),as.data.frame(actual)))
# Changed historical metadata must be refused.
bad<-copy(m4);bad[1L,title_norm:="CHANGED"]
badfile<-file.path(root,"bad.csv");fwrite(bad,badfile)
run(c("--mode","append","--metadata",badfile,"--state",state2,
 "--output",file.path(root,"bad.rds")),FALSE)
cat("PASS: repeated incremental q-gram frequencies equal full rebuild; historical edits refused\n")
