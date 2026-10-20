#!/usr/bin/env Rscript
# Local-only parity / negative-control tests against the existing experimental builder.
suppressPackageStartupMessages({library(data.table);library(jsonlite)})
root<-tempfile("w01-fast-exact-");dir.create(root)
script<-"scripts/updater/experimental_w01_fast/persistent_exact_index.R"
reference<-"scripts/updater/experimental_w01_fast/build_exact_block_index.R"
m<-data.table(idx=1:4,source=c("a","b","c","d"),
 source_record_id=c("A","B","C","D"),
 title_norm=c("salmon1","salmon2","salmon1","salmon2"),
 doi_norm=c("10/a","10/b","10/a","10/b"),
 doi_family=c("10/a","10/b","10/a","10/b"),
 abstract_hash=c("h1","h2","h1","h2"),
 author_norm=c("smith","brown","smith","brown"),
 year=c(2020L,2021L,2020L,2021L),
 journal_norm=c("j","j","j","j"),volume_norm=c("1","2","1","2"),
 issue_norm=c("1","1","1","1"),pages_norm=c("10","20","10","20"))
run<-function(script,args,ok=TRUE){
 log<-suppressWarnings(system2(file.path(R.home("bin"),"Rscript"),
   c(script,args),stdout=TRUE,stderr=TRUE))
 status<-attr(log,"status");if(is.null(status))status<-0L
 if((status==0L)!=ok)stop(sprintf("Unexpected result %d: %s",status,paste(log,collapse=" | ")))
}
base<-file.path(root,"baseline.csv");full<-file.path(root,"full.csv")
fwrite(m[1:2],base);fwrite(m,full)
init<-file.path(root,"initial");dir.create(init)
run(script,c("--mode","init","--metadata",base,"--state",file.path(root,"new_state.rds"),
 "--output-dir",init))
next_out<-file.path(root,"next")
run(script,c("--mode","append","--metadata",full,"--state",file.path(init,"next_exact_index.rds"),
 "--output-dir",next_out))
ref_out<-file.path(root,"ref")
run(reference,c("--metadata",full,"--prior-n","2","--output-dir",ref_out))
a<-fread(file.path(next_out,"exact_block_candidates.csv"))
b<-fread(file.path(ref_out,"exact_block_candidates.csv"))
setorder(a,record_i,record_j);setorder(b,record_i,record_j)
stopifnot(identical(a,b),nrow(a)>0L)
# Historical source ID change must be rejected.
bad<-copy(m);bad[1L,source_record_id:="CHANGED"]
bad_path<-file.path(root,"bad.csv");fwrite(bad,bad_path)
run(script,c("--mode","append","--metadata",bad_path,
 "--state",file.path(init,"next_exact_index.rds"),
 "--output-dir",file.path(root,"reject_id")),FALSE)
# Historical metadata changes require explicit rebuild rather than stale reuse.
bad<-copy(m);bad[1L,doi_norm:="10/changed"];fwrite(bad,bad_path)
run(script,c("--mode","append","--metadata",bad_path,
 "--state",file.path(init,"next_exact_index.rds"),
 "--output-dir",file.path(root,"reject_repair")),FALSE)
cat("PASS: persistent exact index parity and stale-history rejection\n")
