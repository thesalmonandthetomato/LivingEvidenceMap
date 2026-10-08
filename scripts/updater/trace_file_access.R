#!/usr/bin/env Rscript
# Diagnostic wrapper for controlled runs. Output only repo-relative paths.
args <- commandArgs(trailingOnly=TRUE)
if(length(args)<3L || args[[2]]!="--")stop("Usage: trace_file_access.R output_dir -- command [args...]")
out<-args[[1]]; cmd<-args[[3]]; cmdargs<-if(length(args)>3L) args[-(1:3)] else character()
dir.create(out,recursive=TRUE,showWarnings=FALSE)
if(!nzchar(Sys.which("strace")))stop("strace is unavailable; install it only in diagnostic job")
log<-file.path(out,"strace.log")
# File syscalls, child processes, no following of networks; do not publish raw syscall logs.
status<-suppressWarnings(system2("strace",args=c("-f","-qq","-s","4096","-e","trace=%file","-o",shQuote(log),shQuote(cmd),vapply(cmdargs,shQuote,character(1))),stdout=FALSE,stderr=FALSE))
lines<-readLines(log,warn=FALSE)
root<-normalizePath(".",winslash="/",mustWork=TRUE)
pattern <- '"([^"]+)"'
records<-list()
for(line in lines){
  quoted<-regmatches(line,gregexpr(pattern,line,perl=TRUE))[[1]]
  if(!length(quoted))next
  hit<-substring(quoted[[1]],2,nchar(quoted[[1]])-1)
  if(!startsWith(hit,"/"))next
  # Do not record secrets, environment or third-party paths.
  if(!startsWith(hit,paste0(root,"/")))next
  rel<-substring(hit,nchar(root)+2)
  mode<-if(grepl("O_WRONLY|O_RDWR|O_CREAT|O_TRUNC|rename|unlink|mkdir",line))"WRITE" else "READ_OR_METADATA"
  records[[length(records)+1L]]<-data.frame(path=rel,access=mode)
}
tab<-if(length(records))unique(do.call(rbind,records)) else data.frame(path=character(),access=character())
write.csv(tab,file.path(out,"runtime_file_access.csv"),row.names=FALSE)
writeLines(c(paste("Command:",cmd),paste("Exit status:",status),"READ_OR_METADATA may indicate stat/access checks, not necessarily file contents read.",
 "Only paths beneath the current checkout are recorded.","Raw strace.log is diagnostic-local and must not be uploaded."),file.path(out,"runtime_notes.txt"))
unlink(log)
if(is.null(status)||is.na(status)) status<-1L
quit(save="no",status=as.integer(status))
