#!/usr/bin/env Rscript
suppressPackageStartupMessages(library(jsonlite))
temp<-tempfile();dir.create(temp)
script<-"scripts/updater/experimental_w01_fast/check_run_readiness.R"
out<-file.path(temp,"report.json")
command<-c(script,"--evidence-dir",file.path(temp,"none"),"--output",out)
suppressWarnings(system2(file.path(R.home("bin"),"Rscript"),command,stdout=TRUE,stderr=TRUE))->z
status<-attr(z,"status")
if(is.null(status)||status!=2L)stop("Absent acceptance evidence must fail closed")
report<-fromJSON(out,simplifyVector=FALSE)
if(report$ready_for_full_frozen_w00_shadow_run||report$ready_for_production_migration||
 any(vapply(report$tests,function(z)isTRUE(z$passed),logical(1))))
 stop("Unsafe acceptance without evidence")
# Invalid evidence and fabricated bare fields must also be rejected.
dir.create(file.path(temp,"fake"))
write_json(list(test="candidate_identity_and_block_parity",passed=TRUE,run_url="invalid"),
 file.path(temp,"fake","candidate_identity_and_block_parity.json"),auto_unbox=TRUE)
out2<-file.path(temp,"report2.json")
z<-suppressWarnings(system2(file.path(R.home("bin"),"Rscript"),
 c(script,"--evidence-dir",file.path(temp,"fake"),"--output",out2),stdout=TRUE,stderr=TRUE))
if(!identical(attr(z,"status"),2L))stop("Invalid acceptance URL must fail")
if(isTRUE(fromJSON(out2,simplifyVector=FALSE)$tests[[1L]]$passed))stop("Invalid proof accepted")
cat("PASS: W01-Fast readiness fails closed with missing or invalid scientific evidence\\n")
