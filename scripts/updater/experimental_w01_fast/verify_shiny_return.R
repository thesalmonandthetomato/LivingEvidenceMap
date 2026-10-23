#!/usr/bin/env Rscript
# Read-only W01 Shiny return verifier. No resume, publication, queue mutation or dispatch.
suppressPackageStartupMessages({library(jsonlite);library(digest)})
a<-commandArgs(trailingOnly=TRUE)
arg<-function(k){i<-match(k,a);if(is.na(i)||i==length(a))stop("Missing ",k);a[[i+1L]]}
handoff<-arg("--handoff");export<-arg("--export-manifest")
decisions<-arg("--decisions");repairs<-arg("--repairs")
queue<-arg("--queue");out<-arg("--output")
required<-c(handoff,export,decisions,repairs,queue)
if(any(!file.exists(required))||file.exists(out))stop("Missing Shiny evidence or existing output")
h<-fromJSON(handoff,simplifyVector=FALSE);d<-fromJSON(export,simplifyVector=FALSE)
must<-function(x,y,n)if(!identical(as.character(x),as.character(y)))stop("Shiny mismatch: ",n)
must(h$schema,"living-evidence-map-workflow01-shiny-handoff-v1","handoff schema")
must(h$status,"ready","handoff readiness")
must(d$schema,"living-evidence-map-workflow01-shiny-decision-export-manifest-v2","export schema")
for(nm in c("checkpoint_pointer_path","checkpoint_run_id","queue_sha256","queue_cases",
              "export_run_id"))must(h[[nm]],d[[nm]],nm)
must(h$decisions_export_sha256,d$export_sha256,"export checksum")
if(!isTRUE(d$complete)||as.integer(d$unresolved_cases)!=0L||
 as.integer(d$uncertain_cases)!=0L)stop("Shiny review incomplete")
hash<-function(f)digest(file=f,algo="sha256",serialize=FALSE)
must(hash(queue),h$queue_sha256,"original queue")
must(hash(decisions),h$decisions_export_sha256,"decisions bytes")
must(hash(repairs),d$repairs_sha256,"repairs bytes")
dir.create(dirname(out),recursive=TRUE,showWarnings=FALSE)
write_json(list(schema="w01-fast-shiny-return-verified-v1",status="VERIFIED_SHINY_RETURN",
 queue_sha256=hash(queue),decision_sha256=hash(decisions),repair_sha256=hash(repairs),
 source_checkpoint_run_id=as.character(h$checkpoint_run_id),
 production_publication_allowed=FALSE,workflow02_dispatch_allowed=FALSE),
 out,auto_unbox=TRUE,pretty=TRUE)
cat("PASS: Shiny ready handoff and immutable exported review inputs verified; no publication\n")
