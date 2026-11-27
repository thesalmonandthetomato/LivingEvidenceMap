#!/usr/bin/env Rscript
# Resolve immutable artifact ownership independently of the Shiny queue owner.
# Explicit recovery lineage is versioned on the production branch.
suppressPackageStartupMessages(library(jsonlite))
resolve_w02_artifact_run <- function(review_run_id, lineage_dir, manifest, actual_review_commit="") {
 valid_id <- function(x) is.character(x)&&length(x)==1L&&!is.na(x)&&grepl("^[0-9]+$",x)
 stopifnot(valid_id(review_run_id),identical(manifest$schema,"living-evidence-map-workflow02-human-review-package-v1"),
           identical(manifest$workflow,"02"))
 p <- file.path(lineage_dir,paste0("run-",review_run_id,".json"))
 embedded <- manifest$artifact_run_id
 if(!is.null(embedded)&&!valid_id(embedded))stop("Invalid review manifest artifact owner")
 if(!is.null(manifest$review_run_id)&&!identical(manifest$review_run_id,review_run_id))stop("Review manifest owner mismatch")
 if(!file.exists(p)){
   if(!is.null(embedded)&&!identical(embedded,review_run_id))stop("Cross-run recovery requires registered lineage")
   return(review_run_id)
 }
 x <- fromJSON(p,simplifyVector=FALSE)
 stopifnot(identical(x$schema,"w02-review-artifact-lineage-v1"),
           identical(x$review_run_id,review_run_id),valid_id(x$artifact_run_id),
           is.character(x$review_run_commit),length(x$review_run_commit)==1L,
           grepl("^[0-9a-f]{40}$",x$review_run_commit),
           identical(x$review_run_commit,actual_review_commit),
           is.character(x$reason),length(x$reason)==1L,nzchar(x$reason))
 if(!is.null(embedded)&&!identical(embedded,x$artifact_run_id))stop("Conflicting artifact lineage")
 x$artifact_run_id
}
if(sys.nframe()==0L){
 a<-commandArgs(TRUE)
 if(length(a)!=4L)stop("Expected review run ID, lineage directory, manifest path, review commit")
 cat(resolve_w02_artifact_run(a[[1]],a[[2]],fromJSON(a[[3]],simplifyVector=FALSE),a[[4]]))
}
