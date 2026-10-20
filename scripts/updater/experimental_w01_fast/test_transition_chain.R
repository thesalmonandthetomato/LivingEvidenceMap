#!/usr/bin/env Rscript
suppressPackageStartupMessages(library(jsonlite))
root<-tempfile("chain-");dir.create(root)
artifact<-file.path(root,"state.csv");writeLines("v1",artifact)
runner<-file.path(R.home("bin"),"Rscript")
invoke<-function(script,args,ok=TRUE){
 z<-suppressWarnings(system2(runner,c(script,args),stdout=TRUE,stderr=TRUE))
 status<-attr(z,"status");if(is.null(status))status<-0L
 if((status==0L)!=ok)stop(paste(status,paste(z,collapse=" | ")))
}
snap<-function(n){out<-file.path(root,paste0("s",n))
 invoke("scripts/updater/experimental_w01_fast/create_state_snapshot.R",
 c("--batch-id",paste0("batch-",n),"--artifact",paste0("state=",artifact),"--output-dir",out));out}
s1<-snap(1);writeLines("v2",artifact);s2<-snap(2)
writeLines("v3",artifact);s3<-snap(3)
link<-function(a,b,n){p<-file.path(root,paste0("t",n,".json"))
 invoke("scripts/updater/experimental_w01_fast/link_state_transition.R",
 c("--before",a,"--after",b,"--output",p));p}
t1<-link(s1,s2,1);t2<-link(s2,s3,2)
chain<-"scripts/updater/experimental_w01_fast/verify_transition_chain.R"
check<-function(ts,ok=TRUE)invoke(chain,c("--snapshot",s1,"--snapshot",s2,"--snapshot",s3,
 "--transition",ts[[1]],"--transition",ts[[2]]),ok)
check(c(t1,t2))
check(c(t2,t1),FALSE)
obj<-fromJSON(t2,simplifyVector=FALSE)
obj$changed_objects<-list("incorrect")
bad<-file.path(root,"tampered.json")
writeLines(toJSON(obj,pretty=TRUE,auto_unbox=TRUE),bad)
check(c(t1,bad),FALSE)
cat("PASS: ordered transition chain detects link order and falsified deltas\n")
