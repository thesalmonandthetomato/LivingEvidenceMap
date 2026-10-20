#!/usr/bin/env Rscript
suppressPackageStartupMessages({library(data.table);library(jsonlite)})
root<-tempfile("real-candidates-");dir.create(root)
old<-file.path(root,"old.csv");new<-file.path(root,"fast.csv")
x<-data.table(source_a="lens",source_record_id_a=c("A","B"),
 source_b="scopus",source_record_id_b=c("X","Y"),evidence=c("doi","title"))
fwrite(x,old);fwrite(x[2:1],new)
script<-"scripts/updater/experimental_w01_fast/compare_real_candidate_pairs.R"
run<-function(dest,ok=TRUE){
 z<-suppressWarnings(system2(file.path(R.home("bin"),"Rscript"),
 c(script,"--reference",old,"--candidate",new,"--output-dir",dest),
 stdout=TRUE,stderr=TRUE))
 code<-attr(z,"status");if(is.null(code))code<-0L
 if((code==0L)!=ok)stop(paste("Unexpected parity result",code,paste(z,collapse=" | ")))
}
first<-file.path(root,"matching");run(first)
r<-fromJSON(file.path(first,"parity_report.json"))
stopifnot(isTRUE(r$parity_passed),r$reference_pairs==2L)
y<-copy(x);y[1,evidence:="not-doi"];fwrite(y,new)
run(file.path(root,"changed-evidence"),FALSE)
y<-x[1];fwrite(y,new)
run(file.path(root,"missing-pair"),FALSE)
y<-rbind(x,x[1]);fwrite(y,new)
run(file.path(root,"duplicate-pair"),FALSE)
# The comparator must regard swapped endpoints as the same identity pair.
y<-copy(x)
for(col in c("source","source_record_id")){
 left<-paste0(col,"_a");right<-paste0(col,"_b")
 tmp<-y[[left]];set(y,j=left,value=y[[right]]);set(y,j=right,value=tmp)
}
fwrite(y,new)
run(file.path(root,"swapped"))
y[,idx:=seq_len(.N)];fwrite(y,new)
run(file.path(root,"positional-identity"),FALSE)
cat("PASS: candidate parity detects drift, missing and duplicate pairs, and forbids positional IDs\\n")
