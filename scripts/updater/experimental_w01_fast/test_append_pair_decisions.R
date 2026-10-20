#!/usr/bin/env Rscript
suppressPackageStartupMessages(library(data.table))
root<-tempfile("decision-ledger-");dir.create(root)
script<-"scripts/updater/experimental_w01_fast/append_pair_decisions.R"
m<-data.table(idx=1:4,source="a",source_record_id=LETTERS[1:4])
mp<-file.path(root,"manifestations.csv");fwrite(m,mp)
old<-data.table(record_i=1L,record_j=2L,rescored_classification="duplicate")
new<-data.table(record_i=3L,record_j=4L,rescored_classification="distinct")
op<-file.path(root,"old.csv");np<-file.path(root,"new.csv")
fwrite(old,op);fwrite(new,np)
run<-function(oldpath,newpath,out,expect_success){
 args<-c(script,if(!is.null(oldpath))c("--historical-ledger",oldpath),
 "--new-decisions",newpath,"--manifestations",mp,
 if(!is.null(oldpath))c("--historical-manifestations",mp),
 "--output",out)
 log<-suppressWarnings(system2(file.path(R.home("bin"),"Rscript"),args,stdout=TRUE,stderr=TRUE))
 status<-attr(log,"status");if(is.null(status))status<-0L
 if((status==0L)!=expect_success)stop(paste(log,collapse=" | "))
}
merged<-file.path(root,"merged.csv")
run(op,np,merged,TRUE)
result<-fread(merged)
stopifnot(nrow(result)==2L,identical(result[1],old))
run(op,np,merged,FALSE) # no overwrite
fwrite(old,np);run(op,np,file.path(root,"duplicate.csv"),FALSE)
fwrite(data.table(record_i=2L,record_j=1L,rescored_classification="duplicate"),np)
run(op,np,file.path(root,"reversed.csv"),FALSE)
fwrite(data.table(record_i=3L,record_j=5L,rescored_classification="distinct"),np)
run(op,np,file.path(root,"outofbounds.csv"),FALSE)

# A changed historical source ID must not be accepted even if pair indices match.
altered<-copy(m);altered[1L,source_record_id:="ALTERED"]
altered_path<-file.path(root,"altered.csv");fwrite(altered,altered_path)
historical_snapshot<-file.path(root,"historical_identity.csv");fwrite(m,historical_snapshot)
log<-suppressWarnings(system2(file.path(R.home("bin"),"Rscript"),
 c(script,"--historical-ledger",op,"--historical-manifestations",historical_snapshot,
 "--new-decisions",np,"--manifestations",altered_path,
 "--output",file.path(root,"identity_mismatch.csv")),
 stdout=TRUE,stderr=TRUE))
stopifnot(!is.null(attr(log,"status")),attr(log,"status")!=0L)
cat("PASS: append-only historical ledger, duplicate, overwrite and identity guards\n")
