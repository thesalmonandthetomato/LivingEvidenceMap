#!/usr/bin/env Rscript
# Immutable content-addressed checkpoint of experimental W01-Fast artefacts.
suppressPackageStartupMessages({library(jsonlite);library(digest)})
args<-commandArgs(trailingOnly=TRUE)
arg<-function(k){i<-match(k,args);if(is.na(i)||i==length(args))stop(paste("Missing",k));args[[i+1L]]}
out<-arg("--output-dir");batch<-arg("--batch-id");fileargs<-which(args=="--artifact")
if(!length(fileargs)||any(fileargs==length(args)))stop("Specify --artifact NAME=PATH")
entries<-args[fileargs+1L];if(any(!grepl("^[a-zA-Z][a-zA-Z0-9_-]*=",entries)))stop("Invalid artifact argument")
names_ <-sub("=.*$","",entries);paths<-sub("^[^=]+=","",entries)
if(anyDuplicated(names_)||!nzchar(batch)||file.exists(out)||dir.exists(out))stop("Invalid/overlapping snapshot")
if(any(!file.exists(paths))||any(dir.exists(paths)))stop("Every artifact must be an existing regular file")
# Stage privately then refuse all overwrite: state is never mutable in place.
dir.create(out,recursive=TRUE)
dir.create(file.path(out,"objects"))
objects<-list()
for(i in seq_along(paths)){
 h<-digest(file=paths[[i]],algo="sha256")
 dest<-file.path(out,"objects",h)
 if(!file.exists(dest)&&!file.copy(paths[[i]],dest,overwrite=FALSE))
  stop("Failed to materialise snapshot object")
 if(!identical(digest(file=dest,algo="sha256"),h))stop("Object checksum mismatch")
 objects[[names_[[i]]]]<-list(sha256=h,bytes=unname(file.info(dest)$size),object=paste0("objects/",h))
}
manifest<-list(schema="experimental-w01-fast-state-v1",batch_id=batch,objects=objects,
 production_publication_allowed=FALSE)
writeLines(toJSON(manifest,auto_unbox=TRUE,pretty=TRUE),
 file.path(out,"manifest.json"))
cat(sprintf("PASS: snapshotted %d verified artifacts for batch %s\n",length(objects),batch))
