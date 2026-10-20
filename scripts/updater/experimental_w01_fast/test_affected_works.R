#!/usr/bin/env Rscript
suppressPackageStartupMessages(library(data.table))
root<-tempfile("affected-");dir.create(root)
script<-"scripts/updater/experimental_w01_fast/identify_affected_works.R"
prior<-data.table(source="a",source_record_id=c("A","B","C"),
 cluster_id=c("old1","old1","old2"))
nextmap<-data.table(source="a",source_record_id=c("A","B","C","D"),
 cluster_id=c("merged","merged","old2","merged"))
oldpath<-file.path(root,"prior.csv");newpath<-file.path(root,"new.csv")
fwrite(prior,oldpath);fwrite(nextmap,newpath)
run<-function(output,ok=TRUE){
 z<-suppressWarnings(system2(file.path(R.home("bin"),"Rscript"),
 c(script,"--prior-map",oldpath,"--next-map",newpath,"--output-dir",output),
 stdout=TRUE,stderr=TRUE))
 status<-attr(z,"status");if(is.null(status))status<-0L
 if((status==0L)!=ok)stop(paste(status,paste(z,collapse=" | ")))
}
out1<-file.path(root,"first");run(out1)
a<-fread(file.path(out1,"affected_works.csv"))
stopifnot(nrow(a)==2L,
 a[stage=="prior",cluster_id]=="old1",
 a[stage=="successor",cluster_id]=="merged")
# Completely permute both maps, preserving identities and memberships.
fwrite(prior[c(3,1,2)],oldpath);fwrite(nextmap[c(4,2,3,1)],newpath)
out2<-file.path(root,"second");run(out2)
stopifnot(identical(a,fread(file.path(out2,"affected_works.csv"))))
# Mutating membership without changing cluster label still requires rematerialisation.
changed<-copy(prior);changed[3L,cluster_id:="old1"]
fwrite(changed,newpath)
out3<-file.path(root,"same-label-changed-members");run(out3)
z<-fread(file.path(out3,"affected_works.csv"))
stopifnot(nrow(z)==3L,
 all(c("old1","old2")%in%z[stage=="prior",cluster_id]),
 "old1"%in%z[stage=="successor",cluster_id])
cat("PASS: affected work detection by immutable membership, regardless of row position\n")
