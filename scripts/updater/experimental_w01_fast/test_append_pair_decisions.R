#!/usr/bin/env Rscript
suppressPackageStartupMessages(library(data.table))
root<-tempfile("identity-ledger-");dir.create(root)
script<-"scripts/updater/experimental_w01_fast/append_pair_decisions.R"
m<-data.table(idx=1:4,source="a",source_record_id=LETTERS[1:4])
mp<-file.path(root,"manifestations.csv");fwrite(m,mp)
old<-data.table(source_i="a",source_record_id_i="A",source_j="a",
 source_record_id_j="B",rescored_classification="duplicate")
new<-data.table(source_i="a",source_record_id_i="C",source_j="a",
 source_record_id_j="D",rescored_classification="distinct")
op<-file.path(root,"old.csv");np<-file.path(root,"new.csv")
fwrite(old,op);fwrite(new,np)
run<-function(oldpath,newpath,manifest,out,expect_success){
 args<-c(script,if(!is.null(oldpath))c("--historical-ledger",oldpath),
 "--new-decisions",newpath,"--manifestations",manifest,"--output",out)
 log<-suppressWarnings(system2(file.path(R.home("bin"),"Rscript"),args,stdout=TRUE,stderr=TRUE))
 status<-attr(log,"status");if(is.null(status))status<-0L
 if((status==0L)!=expect_success)stop(paste(log,collapse=" | "))
}
merged<-file.path(root,"merged.csv")
run(op,np,mp,merged,TRUE)
stopifnot(identical(fread(merged),rbindlist(list(old,new))))
run(op,np,mp,merged,FALSE)
# Permuting every row must leave recorded identities and decisions unchanged.
reordered<-file.path(root,"permuted.csv")
fwrite(m[c(4,2,1,3)],reordered)
permuted_output<-file.path(root,"permuted_out.csv")
run(op,np,reordered,permuted_output,TRUE)
stopifnot(identical(fread(merged),fread(permuted_output)))
# Reuse of an existing pair, or reversed identity order, must fail closed.
fwrite(old,np)
run(op,np,mp,file.path(root,"duplicate.csv"),FALSE)
fwrite(new[,.(source_i=source_j,source_record_id_i=source_record_id_j,
 source_j=source_i,source_record_id_j=source_record_id_i,
 rescored_classification)],np)
run(op,np,mp,file.path(root,"reversed.csv"),FALSE)
fwrite(new[,source_record_id_j:="UNKNOWN"],np)
run(op,np,mp,file.path(root,"unknown.csv"),FALSE)
# No idx-based schema is permitted.
fwrite(data.table(record_i=3L,record_j=4L,rescored_classification="distinct"),np)
run(op,np,mp,file.path(root,"numeric.csv"),FALSE)
cat("PASS: identity-keyed ledger is invariant to row permutations and rejects unsafe inputs\\n")
