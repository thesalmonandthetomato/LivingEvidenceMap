#!/usr/bin/env Rscript
suppressPackageStartupMessages(library(jsonlite))
args<-commandArgs(trailingOnly=TRUE)
arg<-function(flag,default=NULL){i<-match(flag,args);if(is.na(i))return(default);if(i==length(args))stop(sprintf("Missing value after %s",flag),call.=FALSE);args[[i+1L]]}
receipt<-arg("--receipt");registry<-arg("--registry");pointer_dir<-arg("--pointer-dir")
if(any(vapply(list(receipt,registry,pointer_dir),is.null,logical(1))))stop("Required: --receipt --registry --pointer-dir",call.=FALSE)
x<-fromJSON(receipt,simplifyVector=FALSE)
if(!identical(x$status,"published")||!identical(x$workflow,"04")||!identical(x$state,"relevance_screening"))stop("Invalid Workflow 04 receipt",call.=FALSE)
dir.create(dirname(registry),recursive=TRUE,showWarnings=FALSE);dir.create(pointer_dir,recursive=TRUE,showWarnings=FALSE)
row<-data.frame(
 source_github_run_id=as.character(x$source_github_run_id),publication_github_run_id=as.character(x$publication_github_run_id),
 upstream_lean_canonical_sha256=as.character(x$upstream_lean_canonical_sha256),upstream_workflow03_publication_status_sha256=as.character(x$upstream_workflow03_publication_status_sha256),
 prompt_sha256=as.character(x$prompt_sha256),workflow04_final_screening_layer_sha256=as.character(x$workflow04_final_screening_layer_sha256),
 included_record_ids_sha256=as.character(x$included_record_ids_sha256),excluded_record_ids_sha256=as.character(x$excluded_record_ids_sha256),
 records=as.integer(x$records),retained=as.integer(x$retained),excluded=as.integer(x$excluded),unresolved=as.integer(x$unresolved),inclusion_rate=as.numeric(x$inclusion_rate),
 zenodo_record_id=as.character(x$zenodo_record_id),doi=as.character(x$doi),record_url=as.character(x$record_url),visibility=as.character(x$visibility),
 manifest_sha256=as.character(x$manifest_sha256),published_at_utc=as.character(x$published_at_utc),stringsAsFactors=FALSE
)
if(file.exists(registry)){
 old<-read.csv(registry,stringsAsFactors=FALSE,check.names=FALSE);old<-old[as.character(old$source_github_run_id)!=row$source_github_run_id,,drop=FALSE]
 cols<-union(names(old),names(row));for(nm in setdiff(cols,names(old)))old[[nm]]<-NA;for(nm in setdiff(cols,names(row)))row[[nm]]<-NA
 out<-rbind(old[,cols,drop=FALSE],row[,cols,drop=FALSE])
}else out<-row
out<-out[order(suppressWarnings(as.numeric(out$source_github_run_id))),,drop=FALSE]
write.csv(out,registry,row.names=FALSE,na="")
pointer<-file.path(pointer_dir,paste0("run-",row$source_github_run_id,".json"))
if(!file.copy(receipt,pointer,overwrite=TRUE))stop("Failed to write Workflow 04 pointer",call.=FALSE)
cat(sprintf("PASS: registered Workflow 04 Zenodo state %s for source run %s\n",row$zenodo_record_id,row$source_github_run_id))
