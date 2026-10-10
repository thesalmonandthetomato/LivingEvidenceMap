#!/usr/bin/env Rscript
# Negative and resumption tests on real local W01 handoff selection; no production services.
suppressPackageStartupMessages(library(jsonlite))
root<-"/tmp/lem-isolated/adjudication"
dir.create(root,recursive=TRUE,showWarnings=FALSE)
p<-function(x)file.path(root,x)
dir.create(p("handoff"),showWarnings=FALSE);dir.create(p("resolved"),showWarnings=FALSE)
run<-function(ok=TRUE){
 o<-suppressWarnings(system2("Rscript",c("scripts/updater/workflow_01_select_ready_handoff.R","--handoff-dir",p("handoff"),"--resolution-dir",p("resolved"),"--output",p("selection.json")),stdout=TRUE,stderr=TRUE))
 pass<-is.null(attr(o,"status"))||attr(o,"status")==0L
 if(pass!=ok)stop(paste(o,collapse=" | "))
 if(pass)fromJSON(p("selection.json"))else invisible(NULL)
}
handoff<-function(id,status="ready",schema="living-evidence-map-workflow01-shiny-handoff-v1")write_json(list(schema=schema,status=status,checkpoint_run_id=id),p(paste0("handoff/run-",id,".json")),auto_unbox=TRUE)
stopifnot(identical(run()$found,FALSE))
handoff("101")
stopifnot(identical(as.character(run()$checkpoint_run_id),"101"))
# A second unresolved ready checkpoint must fail closed.
handoff("102")
run(FALSE)
# Resolution suppresses only the matching handoff.
write_json(list(status="resolved"),p("resolved/run-101.json"),auto_unbox=TRUE)
stopifnot(identical(as.character(run()$checkpoint_run_id),"102"))
# An unresolved decision does not mark a checkpoint completed.
write_json(list(status="pending"),p("resolved/run-102.json"),auto_unbox=TRUE)
stopifnot(identical(as.character(run()$checkpoint_run_id),"102"))
write_json(list(status="resolved"),p("resolved/run-102.json"),auto_unbox=TRUE)
stopifnot(identical(run()$found,FALSE),identical(run()$found,FALSE))
# Invalid run identity must be rejected instead of guessed.
write_json(list(schema="living-evidence-map-workflow01-shiny-handoff-v1",status="ready",checkpoint_run_id="wrong"),p("handoff/run-103.json"),auto_unbox=TRUE)
run(FALSE)
write_json(list(status="PASS",w01_multiple_unresolved_rejected=TRUE,w01_resolution_record_specific=TRUE,w01_pending_stays_open=TRUE,w01_repeated_resume_idempotent=TRUE,w01_bad_run_identifier_rejected=TRUE,scope="Local handoff selector only, not a complete Shiny reviewer round-trip"),p("adjudication-report.json"),auto_unbox=TRUE,pretty=TRUE)
cat("PASS: W01 local handoff selector negative and repeat-resume checks\n")
