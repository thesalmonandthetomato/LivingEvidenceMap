#!/usr/bin/env Rscript
# Experimental only. Compare production and W01-Fast cluster maps exactly.
suppressPackageStartupMessages({library(data.table);library(jsonlite);library(digest)})
args<-commandArgs(trailingOnly=TRUE)
arg<-function(flag){i<-match(flag,args);if(is.na(i)||i==length(args))stop(paste("Missing",flag),call.=FALSE);args[[i+1L]]}
production<-arg("--production-map");fast<-arg("--fast-map");out<-arg("--report")
load_map<-function(path){
 x<-fread(path)
 required<-c("idx","source","source_record_id","cluster_id","cluster_size")
 stopifnot(all(required%in%names(x)),!anyNA(x[,..required]))
 setorder(x,idx)
 stopifnot(identical(as.integer(x$idx),seq_len(nrow(x))),
           !anyDuplicated(paste(x$source,x$source_record_id,sep="::")))
 x[,..required]
}
a<-load_map(production);b<-load_map(fast)
stopifnot(nrow(a)==nrow(b),
  identical(a$idx,b$idx),
  identical(as.character(a$source),as.character(b$source)),
  identical(as.character(a$source_record_id),as.character(b$source_record_id)))
diff<-a[cluster_id!=b$cluster_id | cluster_size!=b$cluster_size]
diff[,fast_cluster_id:=b$cluster_id[match(idx,b$idx)]]
diff[,fast_cluster_size:=b$cluster_size[match(idx,b$idx)]]
size_a<-a[,.(computed=.N),by=cluster_id]
size_b<-b[,.(computed=.N),by=cluster_id]
stopifnot(all(a$cluster_size==size_a$computed[match(a$cluster_id,size_a$cluster_id)]),
          all(b$cluster_size==size_b$computed[match(b$cluster_id,size_b$cluster_id)]))
dir.create(dirname(out),recursive=TRUE,showWarnings=FALSE)
fwrite(diff,paste0(out,".differences.csv"))
result<-list(schema="experimental-w01-fast-cluster-parity-v1",
  manifestations=nrow(a),production_clusters=uniqueN(a$cluster_id),
  fast_clusters=uniqueN(b$cluster_id),differing_manifestations=nrow(diff),
  exact_parity=nrow(diff)==0L,
  production_sha256=digest(file=production,algo="sha256",serialize=FALSE),
  experimental_sha256=digest(file=fast,algo="sha256",serialize=FALSE),
  production_publication_allowed=FALSE)
writeLines(toJSON(result,auto_unbox=TRUE,pretty=TRUE),out)
cat(sprintf("CLUSTER PARITY: %d manifestations; production=%d fast=%d clusters; differences=%d\n",
 nrow(a),uniqueN(a$cluster_id),uniqueN(b$cluster_id),nrow(diff)))
if(nrow(diff))quit(save="no",status=2L)
