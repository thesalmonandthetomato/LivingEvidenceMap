#!/usr/bin/env Rscript
suppressPackageStartupMessages({library(data.table);library(jsonlite)})
root<-tempfile("w01-fast-ledger-");dir.create(root);on.exit(unlink(root,recursive=TRUE),add=TRUE)
file<-function(n)file.path(root,n)
m<-data.table(idx=1:3,source=c("a","b","c"),source_record_id=c("a1","b1","c1"))
fwrite(m,file("metadata.csv"))
p<-data.table(record_i=1L,record_j=2L,source_i="a",source_record_id_i="a1",
source_j="b",source_record_id_j="b1",rescored_classification="duplicate",
rescored_rule="bramer_A",review_route="automatic_duplicate")
fwrite(p,file("old.csv"))
n<-data.table(record_i=1L,record_j=3L,classification="unresolved",
rule="candidate_only",rescored_classification="unresolved",
rescored_rule="candidate_only",review_route="non_duplicate")
# Initial cross-version field mismatch must fail closed, never fill scientific provenance.
fwrite(n,file("new.csv"))
script<-"scripts/updater/experimental_w01_fast/stage_production_pair_ledger.R"
run<-function(out){
 z<-suppressWarnings(system2(file.path(R.home("bin"),"Rscript"),
 c(script,"--previous-decisions",file("old.csv"),"--scored-decisions",
 file("new.csv"),"--metadata",file("metadata.csv"),"--output",out),stdout=TRUE,stderr=TRUE))
 if(is.null(attr(z,"status")))0L else attr(z,"status")
}
stopifnot(run(file("unmapped.csv"))!=0L)
p[,classification:="duplicate"];p[,rule:="bramer_A"]
fwrite(p,file("old.csv"))
fwrite(n,file("new.csv"))
stopifnot(run(file("ledger.csv"))==0L)
z<-fread(file("ledger.csv"));stopifnot(nrow(z)==2L,z$source_j[[2L]]=="c",z$source_record_id_j[[2L]]=="c1")
p[,source_record_id_i:="wrong"];fwrite(p,file("old.csv"))
stopifnot(run(file("bad.csv"))!=0L)
cat("PASS: validated immutable identities, consistent production schema, and refusal of mismatched previous state\\n")
