#!/usr/bin/env Rscript
# Experimental read-only candidate-parity report. No external writes or state updates.
suppressPackageStartupMessages({library(data.table);library(jsonlite);library(digest)})
args<-commandArgs(trailingOnly=TRUE)
arg<-function(flag){i<-match(flag,args);if(is.na(i)||i==length(args))stop(paste("Missing",flag),call.=FALSE);args[[i+1L]]}
production<-arg("--production");experimental<-arg("--experimental");out<-arg("--report")
read_candidates<-function(path){
 x<-fread(path,na.strings=c("","NA"))
 req<-c("record_i","record_j","blocks")
 stopifnot(all(req%in%names(x)),!anyNA(x$record_i),!anyNA(x$record_j),
           all(x$record_i<x$record_j),!anyDuplicated(x[,.(record_i,record_j)]))
 x[,.(record_i=as.integer(record_i),record_j=as.integer(record_j),
     blocks=vapply(strsplit(as.character(blocks),";",fixed=TRUE),
                   function(v) paste(sort(unique(trimws(v))),collapse=";"),character(1)))]
}
a<-read_candidates(production);b<-read_candidates(experimental)
setkey(a,record_i,record_j);setkey(b,record_i,record_j)
missing<-fsetdiff(a[,.(record_i,record_j)],b[,.(record_i,record_j)])
extra<-fsetdiff(b[,.(record_i,record_j)],a[,.(record_i,record_j)])
joint<-merge(a,b,by=c("record_i","record_j"),suffixes=c("_production","_fast"))
changed<-joint[blocks_production!=blocks_fast]
dir.create(dirname(out),recursive=TRUE,showWarnings=FALSE)
report<-list(schema="experimental-w01-fast-candidate-parity-v1",
             production_pairs=nrow(a),experimental_pairs=nrow(b),
             missing_pairs=nrow(missing),extra_pairs=nrow(extra),
             differing_block_provenance=nrow(changed),
             production_sha256=digest(file=production,algo="sha256",serialize=FALSE),
             experimental_sha256=digest(file=experimental,algo="sha256",serialize=FALSE),
             exact_parity=nrow(missing)==0L&&nrow(extra)==0L&&nrow(changed)==0L,
             production_publication_allowed=FALSE)
writeLines(toJSON(report,pretty=TRUE,auto_unbox=TRUE),out)
fwrite(missing,paste0(out,".missing.csv"))
fwrite(extra,paste0(out,".extra.csv"))
fwrite(changed,paste0(out,".block_differences.csv"))
cat(sprintf("PARITY: production=%d fast=%d missing=%d extra=%d block differences=%d\n",
 nrow(a),nrow(b),nrow(missing),nrow(extra),nrow(changed)))
if(!report$exact_parity)quit(save="no",status=2L)
