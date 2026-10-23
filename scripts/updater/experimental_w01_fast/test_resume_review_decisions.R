#!/usr/bin/env Rscript
suppressPackageStartupMessages({library(data.table);library(jsonlite);library(digest)})
root<-tempfile("fast-human-test-");dir.create(root)
on.exit(unlink(root,recursive=TRUE,force=TRUE),add=TRUE)
at<-function(...)file.path(root,...)
dir.create(at("fast","rescored"),recursive=TRUE)
dir.create(at("fast","adjudication","human_review_package"),recursive=TRUE)
m<-data.table(idx=1:3,source=c("a","b","c"),source_record_id=c("a1","b1","c1"))
fwrite(m,at("meta.csv"));fwrite(m[1:2],at("oldmap.csv"))
old<-data.table(record_i=1L,record_j=2L,classification="duplicate",
 rule="bramer_A",rescored_classification="duplicate",rescored_rule="bramer_A",
 review_route="automatic_duplicate",source_i="a",source_record_id_i="a1",
 source_j="b",source_record_id_j="b1")
fwrite(old,at("old.csv"))
fresh<-data.table(record_i=1L,record_j=3L,classification="review",
 rule="candidate_only",rescored_classification="review",rescored_rule="human_review",
 review_route="manual_review")
fwrite(fresh,at("fast","rescored","rescored_sample.csv"))
write_json(list(status="AWAITING_HUMAN_REVIEW"),at("fast","run_report.json"),auto_unbox=TRUE)
stable<-paste(sort(c("a:a1","c:c1")),collapse="|")
id<-paste0("hr-",substr(digest(stable,algo="sha256",serialize=FALSE),1,20))
q<-list(review_case_id=id,pair_key="1::3",
 record_i=list(source="a",source_record_id="a1"),
 record_j=list(source="c",source_record_id="c1"))
qp<-at("fast","adjudication","human_review_package","human_review_cases.jsonl")
writeLines(toJSON(q,auto_unbox=TRUE),qp)
sha<-digest(file=qp,algo="sha256")
decision<-list(review_case_id=id,queue_sha256=sha,decision="duplicate",
 rationale="Verified same article",reviewer="fixture",resolved_at_utc="2026-10-23T00:00:00Z")
writeLines(toJSON(decision,auto_unbox=TRUE),at("decisions.jsonl"))
file.create(at("repairs.jsonl"))
write_json(list(schema="w01-fast-shiny-return-verified-v1",status="VERIFIED_SHINY_RETURN",queue_sha256=sha,
 decision_sha256=digest(file=at("decisions.jsonl"),algo="sha256"),
 repair_sha256=digest(file=at("repairs.jsonl"),algo="sha256"),
 production_publication_allowed=FALSE,workflow02_dispatch_allowed=FALSE),at("verified_shiny.json"),auto_unbox=TRUE)

exe<-"scripts/updater/experimental_w01_fast/resume_review_decisions.R"
call<-function(out,decisions=at("decisions.jsonl"),repairs=at("repairs.jsonl")){
 z<-suppressWarnings(system2(file.path(R.home("bin"),"Rscript"),c(exe,
 "--fast-root",at("fast"),"--metadata",at("meta.csv"),
 "--previous-map",at("oldmap.csv"),"--previous-decisions",at("old.csv"),
 "--queue",qp,"--decisions",decisions,"--repairs",repairs,
 "--verified-shiny-return",at("verified_shiny.json"),
 "--output-dir",out),stdout=TRUE,stderr=TRUE))
 if(is.null(attr(z,"status")))0L else as.integer(attr(z,"status"))
}
stopifnot(call(at("valid"))==0L)
z<-fread(at("valid","resolved_scoring.csv"))
stopifnot(nrow(z)==1L,z$rescored_classification=="duplicate")
manifest<-fromJSON(at("valid","resume_manifest.json"))
stopifnot(manifest$status=="VALIDATED_RESUME_READY",manifest$decision_count==1L)
stopifnot(fread(at("fast","rescored","rescored_sample.csv"))$rescored_classification=="review")
decision$decision<-"uncertain"
writeLines(toJSON(decision,auto_unbox=TRUE),at("uncertain.jsonl"))
stopifnot(call(at("uncertain"),at("uncertain.jsonl"))!=0L)
decision$decision<-"duplicate";decision$queue_sha256<-"invalid"
writeLines(toJSON(decision,auto_unbox=TRUE),at("wrong_hash.jsonl"))
stopifnot(call(at("wrong_hash"),at("wrong_hash.jsonl"))!=0L)
writeLines(toJSON(list(review_case_id=id,action="strip_abstract"),auto_unbox=TRUE),at("repairs_bad.jsonl"))
stopifnot(call(at("repairs"),repairs=at("repairs_bad.jsonl"))!=0L)
cat("PASS: authentic human decision resumes, uncertain/hash mismatch/repairs fail closed; original scores preserved\n")


# Existing Shiny ready-handoff/export manifest must agree byte-for-byte.
writeLines(toJSON(list(schema="living-evidence-map-workflow01-shiny-handoff-v1",
status="ready",checkpoint_pointer_path="docs/test_pointer.json",
checkpoint_run_id="1234",queue_sha256=sha,queue_cases=1L,
export_run_id="5678",decisions_export_sha256=digest(file=at("decisions.jsonl"),algo="sha256")),
auto_unbox=TRUE),at("handoff.json"))
writeLines(toJSON(list(schema="living-evidence-map-workflow01-shiny-decision-export-manifest-v2",
checkpoint_pointer_path="docs/test_pointer.json",checkpoint_run_id="1234",
queue_sha256=sha,queue_cases=1L,export_run_id="5678",
export_sha256=digest(file=at("decisions.jsonl"),algo="sha256"),
repairs_sha256=digest(file=at("repairs.jsonl"),algo="sha256"),
complete=TRUE,unresolved_cases=0L,uncertain_cases=0L),auto_unbox=TRUE),at("export.json"))
verify<-function(handoff=at("handoff.json"),out=at("shiny-verified.json")){
 z<-suppressWarnings(system2(file.path(R.home("bin"),"Rscript"),
 c("scripts/updater/experimental_w01_fast/verify_shiny_return.R",
 "--handoff",handoff,"--export-manifest",at("export.json"),
 "--decisions",at("decisions.jsonl"),"--repairs",at("repairs.jsonl"),
 "--queue",qp,"--output",out),stdout=TRUE,stderr=TRUE))
 if(is.null(attr(z,"status")))0L else as.integer(attr(z,"status"))
}
stopifnot(verify()==0L)
stopifnot(fromJSON(at("shiny-verified.json"))$status=="VERIFIED_SHINY_RETURN")
bad<-fromJSON(at("handoff.json"));bad$queue_sha256<-"tampered"
write_json(bad,at("tampered-handoff.json"),auto_unbox=TRUE)
stopifnot(verify(at("tampered-handoff.json"),at("tampered-result.json"))!=0L)
cat("PASS: authentic Shiny handoff hashes accepted; mismatched queue rejected\\n")
