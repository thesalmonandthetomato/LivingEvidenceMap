#!/usr/bin/env Rscript
suppressPackageStartupMessages(library(data.table))
root<-tempfile("qgram-pairs-");dir.create(root)
rscript<-file.path(R.home("bin"),"Rscript")
run<-function(script,args){
 log<-suppressWarnings(system2(rscript,c(script,args),stdout=TRUE,stderr=TRUE))
 code<-attr(log,"status");if(is.null(code))code<-0L
 if(code!=0L)stop(paste(log,collapse=" | "))
}
m<-data.table(idx=1:5,source="a",source_record_id=LETTERS[1:5],
 title_norm=c("abcdefghijklmnop","abcdefghijklmnop","qrstuvwxyzabcd",
 "abcdefghijklmnop","qrstuvwxyzabcd"))
input<-file.path(root,"m.csv");fwrite(m,input)
base<-file.path(root,"base.csv");fwrite(m[1:3],base)
state0<-file.path(root,"init.rds")
state1<-file.path(root,"append.rds")
run("scripts/updater/experimental_w01_fast/persistent_qgram_frequency.R",
 c("--mode","init","--metadata",base,"--output",state0))
run("scripts/updater/experimental_w01_fast/persistent_qgram_frequency.R",
 c("--mode","append","--metadata",input,"--state",state0,"--output",state1))
out<-file.path(root,"new.csv")
run("scripts/updater/experimental_w01_fast/persistent_qgram_candidates.R",
 c("--state",state1,"--prior-n","3","--output",out))
reference_dir<-file.path(root,"reference")
run("scripts/updater/experimental_w01_fast/build_fuzzy_candidates.R",
 c("--metadata",input,"--prior-n","3","--output-dir",reference_dir))
actual<-fread(out);expected<-fread(file.path(reference_dir,"fuzzy_candidates.csv"))
setorder(actual,record_i,record_j);setorder(expected,record_i,record_j)
stopifnot(identical(names(actual),names(expected)),nrow(actual)>0L,
 identical(actual$record_i,expected$record_i),
 identical(actual$record_j,expected$record_j),
 identical(actual$shared_rare_qgrams,expected$shared_rare_qgrams),
 isTRUE(all.equal(actual$len_ratio,expected$len_ratio)))
cat("PASS: persisted fuzzy candidates match independent reference builder\n")
