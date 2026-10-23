#!/usr/bin/env Rscript
# Run the unmodified production canonical builder against a real approved edit.
suppressPackageStartupMessages({library(data.table);library(jsonlite);library(digest)})
root<-tempfile("w01-fast-canonical-approved-edit-");dir.create(root)
on.exit(unlink(root,recursive=TRUE,force=TRUE),add=TRUE)
at<-function(...)file.path(root,...)
write_json<-function(x,p)writeLines(toJSON(x,auto_unbox=TRUE,null="null"),p)
source<-list(source=list(provider="fixture"),sidecar_identity=list(sidecar_record_id="R1"),
 mapped_fields=list(title="Original title",abstract="Original abstract",doi="10.1234/example"))
write_json(source,at("fixture.jsonl"))
write_json(list(schema="living-evidence-map-workflow01-source-inputs-v1",
 sources=list(fixture=at("fixture.jsonl"))),at("sources.json"))
fwrite(data.table(idx=1L,source="fixture",source_record_id="R1",
 cluster_id="work-1",cluster_size=1L),at("map.csv"))
file.create(at("strips.jsonl"))
repair<-list(review_case_id="hr-fixture",source="fixture",source_record_id="R1",
 action="set_title",value="Corrected title",reason="Verified against primary source",
 reviewer="fixture")
write_json(repair,at("repairs.jsonl"))
argv<-c("scripts/updater/workflow_01_build_canonical_jsonl.R",
 "--cluster-map",at("map.csv"),"--input-manifest",at("sources.json"),
 "--run-id","w01-fast-acceptance-fixture",
 "--strip-actions",at("strips.jsonl"),
 "--data-quality-repairs",at("repairs.jsonl"),
 "--output",at("canonical.jsonl"),"--manifest",at("manifest.json"),
 "--repair-audit",at("audit.jsonl"))
result<-suppressWarnings(system2(file.path(R.home("bin"),"Rscript"),argv,
 stdout=TRUE,stderr=TRUE))
if(!is.null(attr(result,"status"))&&attr(result,"status")!=0L)
 stop(paste(result,collapse=" | "))
records<-lapply(readLines(at("canonical.jsonl")),function(x)fromJSON(x,simplifyVector=FALSE))
stopifnot(length(records)==1L,
 identical(records[[1]]$identity$record_id,"work-1"),
 identical(records[[1]]$canonical$title,"Corrected title"),
 identical(records[[1]]$canonical$abstract,"Original abstract"),
 length(readLines(at("audit.jsonl")))>0L)
cat("PASS: unmodified production canonical builder applied approved human title repair and emitted audit\n")
