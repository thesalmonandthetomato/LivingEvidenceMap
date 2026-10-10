#!/usr/bin/env Rscript
# Isolated executable W02 -> W03 -> W04 -> W05 handoff and W05 on-disk hash verification.
suppressPackageStartupMessages({library(jsonlite);library(digest)})
root <- "/tmp/lem-isolated/linked"
dir.create(root,recursive=TRUE,showWarnings=FALSE)
p <- function(s) file.path(root,s)
run <- function(script,args) {
  out<-suppressWarnings(system2("Rscript",c(script,args),stdout=TRUE,stderr=TRUE))
  status<-attr(out,"status")
  if(!is.null(status)&&status!=0L) stop(paste(c(script,out),collapse=" | "))
  cat(paste(out,collapse="\n"),"\n")
}
jwrite <- function(x,path) writeLines(vapply(x,toJSON,character(1),auto_unbox=TRUE,null="null"),path)
rows <- list(
 list(identity=list(record_id="linked-a"),canonical=list(title="Climate adaptation synthesis",abstract="Field evidence for climate adaptation"),manifestations=list(list(source="lens",source_record_id="a1"),list(source="scopus",source_record_id="a2"))),
 list(identity=list(record_id="linked-b"),canonical=list(title="Retraction: Biodiversity synthesis",abstract="This article has been retracted"),manifestations=list(list(source="lens",source_record_id="b1"))))
jwrite(rows,p("heavy.jsonl"))
run("scripts/updater/workflow_02_compact_post_w02_canonical.R",c("--input",p("heavy.jsonl"),"--output",p("lean.jsonl"),"--report",p("w02-report.json")))
stopifnot(length(readLines(p("lean.jsonl")))==2)
run("scripts/updater/workflow_03_publication_status.R",c("--input",p("lean.jsonl"),"--output",p("w03.jsonl"),"--audit",p("w03-audit.jsonl"),"--report",p("w03-report.json")))
run("scripts/updater/workflow_04_prepare_incremental.R",c("--canonical",p("lean.jsonl"),"--workflow03-status",p("w03.jsonl"),"--output-dir",p("w04")))
m<-fromJSON(p("w04/prepare_manifest.json"))
stopifnot(m$canonical_records==2,m$workflow03_excluded==1,m$screen_queue_records==1)
ids<-readLines(p("w04/screen_queue_record_ids.txt"))
stopifnot(identical(ids,"linked-a"))
# Synthetic positive decision is deliberately supplied at the human screening boundary.
writeLines(ids,p("human-included-ids.txt"))
run("scripts/updater/workflow_05_materialise_retained.R",c("--canonical",p("lean.jsonl"),"--included-ids",p("human-included-ids.txt"),"--output",p("w05-retained.jsonl"),"--expected-records","1"))
out<-readLines(p("w05-retained.jsonl"))
stopifnot(length(out)==1,identical(fromJSON(out[[1]])$identity$record_id,"linked-a"))
sha<-digest(file=p("w05-retained.jsonl"),algo="sha256",serialize=FALSE)
stopifnot(!identical(sha,digest("",algo="sha256",serialize=FALSE)))
write_json(list(status="PASS",handoff="W02->W03->W04->W05",canonical_records=2,w03_excluded=1,w04_queued=1,w05_included=1,w05_sha256=sha,w02_input_sha256=digest(file=p("heavy.jsonl"),algo="sha256",serialize=FALSE)),p("linked-report.json"),auto_unbox=TRUE,pretty=TRUE)
cat("PASS: actual W02-W05 data handoff, one retained record, nonempty on-disk SHA256=",sha,"\n")
