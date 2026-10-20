#!/usr/bin/env Rscript
# Synthetic, offline contract test: adapter -> UNCHANGED W04 merge -> W05.
suppressPackageStartupMessages({library(jsonlite)})
root <- tempfile("w04-offline-");dir.create(root)
on.exit(unlink(root,recursive=TRUE),add=TRUE)
writej <- function(rows,path)writeLines(vapply(rows,toJSON,character(1),
  auto_unbox=TRUE,null="null",na="null"),path)
canonical <- file.path(root,"canonical.jsonl")
w03 <- file.path(root,"w03.jsonl")
reconciled <- file.path(root,"resolved.jsonl")
cp <- lapply(c("r1","r2","r3"),function(id)
  list(identity=list(record_id=id),canonical=list(title=paste("Title",id))))
ws <- lapply(c("r1","r2","r3"),function(id)
  list(record_id=id,publication_status=list(exclude_from_workflow04=FALSE)))
model <- toJSON(list(record_id="r1",screening=list(decision="retain",
  model="test",prompt_sha256=paste(rep("a",64),collapse=""))),
  auto_unbox=TRUE)
decisions <- list(
 list(record_id="r1",status="resolved",decision="retain",
      model_result_json=as.character(model),source_run_ids=list("123")),
 list(record_id="r2",status="resolved",decision="exclude",
      human_decision="exclude",source_run_ids=list()),
 list(record_id="r3",status="resolved",decision="retain",
      human_decision="retain",source_run_ids=list()))
writej(cp,canonical);writej(ws,w03);writej(decisions,reconciled)
inp <- file.path(root,"adapter")
run <- function(script,args) {
  status<-system2("Rscript",c(script,args),stdout=TRUE,stderr=TRUE)
  if(!is.null(attr(status,"status"))&&attr(status,"status")!=0L)
    stop(paste(status,collapse="\n"))
}
run("scripts/updater/workflow_04_prepare_reconciled_offline.R",c(
 "--canonical",canonical,"--workflow03-status",w03,
 "--reconciled",reconciled,"--output-dir",inp))
out <- file.path(root,"final")
run("scripts/updater/workflow_04_merge_incremental.R",c(
 "--canonical",canonical,"--workflow03-status",w03,
 "--reused-layer",file.path(inp,"reused_workflow04_layer.jsonl"),
 "--new-consensus",file.path(inp,"workflow04_consensus_layer.jsonl"),
 "--prepare-manifest",file.path(inp,"prepare_manifest.json"),
 "--output-dir",out))
summary <- fromJSON(file.path(out,"summary.json"))
stopifnot(summary$status=="PASS",summary$workflow03_eligible==3,
 summary$final_retain==2,summary$final_exclude==1,
 summary$unresolved==0)
materialised <- file.path(root,"retained.jsonl")
run("scripts/updater/workflow_05_materialise_retained.R",c(
 "--canonical",canonical,
 "--included-ids",file.path(out,"workflow04_included_record_ids.txt"),
 "--output",materialised,"--expected-records","2"))
stopifnot(length(readLines(materialised))==2L)
# A missing canonical decision must fail closed.
writej(decisions[1:2],reconciled)
failure<-tryCatch(run("scripts/updater/workflow_04_prepare_reconciled_offline.R",c(
 "--canonical",canonical,"--workflow03-status",w03,
 "--reconciled",reconciled,"--output-dir",file.path(root,"fail"))),
 error=identity)
stopifnot(inherits(failure,"error"))
cat("PASS offline reconciled W04 merge and W05 materialisation\n")
