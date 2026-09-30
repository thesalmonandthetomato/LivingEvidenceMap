#!/usr/bin/env Rscript
suppressPackageStartupMessages(library(jsonlite))
args<-commandArgs(trailingOnly=TRUE)
arg<-function(flag,default=NULL){i<-match(flag,args);if(is.na(i))return(default);if(i==length(args))stop(sprintf("Missing value after %s",flag),call.=FALSE);args[[i+1L]]}
receipt<-arg("--receipt");registry<-arg("--registry");pointer_dir<-arg("--pointer-dir")
if(any(vapply(list(receipt,registry,pointer_dir),is.null,logical(1))))stop("Required: --receipt --registry --pointer-dir",call.=FALSE)
x<-fromJSON(receipt,simplifyVector=FALSE)
if(!identical(x$status,"published")||!identical(x$workflow,"07")||!identical(x$state,"topic_coding_and_qc"))stop("Invalid Workflow 07 receipt",call.=FALSE)
dir.create(dirname(registry),recursive=TRUE,showWarnings=FALSE);dir.create(pointer_dir,recursive=TRUE,showWarnings=FALSE)
row<-data.frame(
 source_github_run_id=as.character(x$source_github_run_id),
 source_github_commit=as.character(x$source_github_commit),
 publication_github_run_id=as.character(x$publication_github_run_id),
 upstream_workflow06_zenodo_record_id=as.character(x$upstream_workflow06_zenodo_record_id),
 upstream_workflow06_geography_layer_sha256=as.character(x$upstream_workflow06_geography_layer_sha256),
 ontology_sha256=as.character(x$ontology_sha256),prompt_sha256=as.character(x$prompt_sha256),
 workflow07_records_sha256=as.character(x$workflow07_records_sha256),
 workflow07_topic_pathway_scores_sha256=as.character(x$workflow07_topic_pathway_scores_sha256),
 workflow07_topic_record_qc_sha256=as.character(x$workflow07_topic_record_qc_sha256),
 records=as.integer(x$records),raw_topic_assignments=as.integer(x$raw_topic_assignments),
 zero_topic_records=as.integer(x$zero_topic_records),late_automatic_exclusions=as.integer(x$late_automatic_exclusions),
 human_adjudication_records=as.integer(x$human_adjudication_records),
 zenodo_record_id=as.character(x$zenodo_record_id),doi=as.character(x$doi),record_url=as.character(x$record_url),
 visibility=as.character(x$visibility),manifest_sha256=as.character(x$manifest_sha256),
 published_at_utc=as.character(x$published_at_utc),stringsAsFactors=FALSE
)
if(file.exists(registry)){old<-read.csv(registry,stringsAsFactors=FALSE,check.names=FALSE);old<-old[as.character(old$source_github_run_id)!=row$source_github_run_id,,drop=FALSE];cols<-union(names(old),names(row));for(nm in setdiff(cols,names(old)))old[[nm]]<-NA;for(nm in setdiff(cols,names(row)))row[[nm]]<-NA;out<-rbind(old[,cols,drop=FALSE],row[,cols,drop=FALSE])}else out<-row
out<-out[order(suppressWarnings(as.numeric(out$source_github_run_id))),,drop=FALSE];write.csv(out,registry,row.names=FALSE,na="")
pointer<-file.path(pointer_dir,paste0("run-",row$source_github_run_id,".json"));if(!file.copy(receipt,pointer,overwrite=TRUE))stop("Failed to write Workflow 07 pointer",call.=FALSE)
cat(sprintf("PASS: registered Workflow 07 Zenodo state %s for source run %s\n",row$zenodo_record_id,row$source_github_run_id))
