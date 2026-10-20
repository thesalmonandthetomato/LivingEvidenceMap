#!/usr/bin/env Rscript
suppressPackageStartupMessages({library(jsonlite);library(digest)})
root<-tempfile("replay-");dir.create(root);runner<-file.path(R.home("bin"),"Rscript")
invoke<-function(script,args,ok=TRUE){
 z<-suppressWarnings(system2(runner,c(script,args),stdout=TRUE,stderr=TRUE))
 code<-attr(z,"status");if(is.null(code))code<-0L
 if((code==0L)!=ok)stop(paste(code,paste(z,collapse=" | ")))
}
artifact<-file.path(root,"state.csv")
s<-character()
for(i in 1:3){
 writeLines(paste0("state-",i),artifact)
 s[[i]]<-file.path(root,paste0("s",i))
 invoke("scripts/updater/experimental_w01_fast/create_state_snapshot.R",
 c("--batch-id",paste0("batch-",i),"--artifact",paste0("clusters=",artifact),
 "--output-dir",s[[i]]))
}
links<-character()
for(i in 1:2){
 links[[i]]<-file.path(root,paste0("link",i,".json"))
 invoke("scripts/updater/experimental_w01_fast/link_state_transition.R",
 c("--before",s[[i]],"--after",s[[i+1]],"--output",links[[i]]))
}
script<-"scripts/updater/experimental_w01_fast/replay_verified_state.R"
baseargs<-c(as.vector(rbind(rep("--snapshot",3),s)),
 as.vector(rbind(rep("--transition",2),links)),"--target-batch","batch-2")
out<-file.path(root,"replayed");invoke(script,c(baseargs,"--output-dir",out))
orig<-fromJSON(file.path(s[[2]],"manifest.json"),simplifyVector=FALSE)
replayed<-fromJSON(file.path(out,"manifest.json"),simplifyVector=FALSE)
stopifnot(identical(orig,replayed))
obj<-replayed$objects$clusters
stopifnot(identical(readLines(file.path(out,obj$object)),"state-2"))
invoke(script,c(baseargs,"--output-dir",out),FALSE)
# Alter link hash and confirm fail-closed without creating output.
tampered<-fromJSON(links[[1]],simplifyVector=FALSE)
tampered$next_manifest_sha256<-paste(rep("0",64),collapse="")
writeLines(toJSON(tampered,pretty=TRUE,auto_unbox=TRUE),links[[1]])
bad<-file.path(root,"invalid")
invoke(script,c(baseargs,"--output-dir",bad),FALSE)
stopifnot(!dir.exists(bad))
cat("PASS: verified checkpoint replay, refusal to overwrite and rejection of tampered chain\n")
