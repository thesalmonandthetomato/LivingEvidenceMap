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
 status<-if(is.null(attr(z,"status")))0L else as.integer(attr(z,"status"))
 if(status!=0L)message("Expected/observed adapter diagnostic: ",paste(z,collapse=" | "))
 status
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
# Valid Shiny edit must survive into an immutable continuation checkpoint.
repair<-list(review_case_id=id,queue_sha256=sha,source="a",source_record_id="a1",
 action="set_title",value="Corrected title",reason="Verified against article",
 recorded_by="fixture",recorded_at_utc="2026-10-23T00:00:00Z")
writeLines(toJSON(repair,auto_unbox=TRUE),at("valid_repairs.jsonl"))
cert<-fromJSON(at("verified_shiny.json"))
cert$repair_sha256<-digest(file=at("valid_repairs.jsonl"),algo="sha256")
write_json(cert,at("verified_shiny.json"),auto_unbox=TRUE)
stopifnot(call(at("valid_repair"),repairs=at("valid_repairs.jsonl"))==0L)
rman<-fromJSON(at("valid_repair","resume_manifest.json"))
stopifnot(rman$repair_count==1L,
 rman$review_repairs_sha256==digest(file=at("valid_repairs.jsonl"),algo="sha256"),
 identical(readLines(at("valid_repair","verified_new_repairs.jsonl")),
 readLines(at("valid_repairs.jsonl"))))

# Run the actual Fast reviewed canonical continuation and direct delta replay.
prior_root<-at("previous")
for(p in c("workflow01_seed","workflow01_full_five_source","canonical","provenance"))
 dir.create(at("previous",p),recursive=TRUE,showWarnings=FALSE)
dir.create(at("current_seed"))
source_record<-function(src,id,title)list(
 source=list(provider=src),
 sidecar_identity=list(sidecar_record_id=id),
 mapped_fields=list(title=title,abstract=paste("Abstract",id),doi=paste0("10.1234/",id)))
for(i in 1:3){
 src<-m$source[[i]];id0<-m$source_record_id[[i]]
 payload<-toJSON(source_record(src,id0,paste("Original",id0)),auto_unbox=TRUE,null="null")
 writeLines(payload,at("current_seed",paste0(src,"_records_for_deduplication.jsonl")))
 if(i<=2)writeLines(payload,at("previous","workflow01_seed",
 paste0(src,"_records_for_deduplication.jsonl")))
}
prior_map<-data.table(idx=1:2,source=c("a","b"),source_record_id=c("a1","b1"),
 cluster_id=c("work-a","work-a"),cluster_size=c(2L,2L),
 cluster_id_origin=c("preserved","preserved"))
fwrite(prior_map,at("oldmap.csv"))
fwrite(prior_map,at("previous","workflow01_full_five_source","manifestation_cluster_map.csv"))
fwrite(old,at("previous","workflow01_full_five_source","final_pair_decisions.csv"))
file.create(at("previous","workflow01_full_five_source","abstract_strip_actions.jsonl"))
file.create(at("previous","provenance","cumulative_data_quality_repairs.jsonl"))
file.create(at("strips.jsonl"));file.create(at("original_repairs.jsonl"))
manifest<-function(names0)list(schema="living-evidence-map-workflow01-source-inputs-v1",
 sources=setNames(lapply(names0,function(src)
 at("current_seed",paste0(src,"_records_for_deduplication.jsonl"))),names0))
write_json(manifest(c("a","b","c")),at("source_manifest.json"),auto_unbox=TRUE)
write_json(manifest(c("a","b")),at("previous_source_manifest.json"),auto_unbox=TRUE)
canonical_args<-c("scripts/updater/workflow_01_build_canonical_jsonl.R",
 "--cluster-map",at("oldmap.csv"),"--input-manifest",at("previous_source_manifest.json"),
 "--run-id","fixture-prior","--strip-actions",at("strips.jsonl"),
 "--data-quality-repairs",at("original_repairs.jsonl"),
 "--output",at("previous","canonical","records.jsonl"),
 "--manifest",at("previous","canonical","canonical_manifest.json"))
invoke<-function(argv){
 z<-suppressWarnings(system2(file.path(R.home("bin"),"Rscript"),argv,
 stdout=TRUE,stderr=TRUE))
 status<-if(is.null(attr(z,"status")))0L else as.integer(attr(z,"status"))
 if(status!=0L)stop(paste(z,collapse=" | "))
 invisible(z)
}
invoke(canonical_args)
write_json(list(status="published",state="final",github_run_id="fixture-prior",
 zenodo_record_id="fixture",doi="fixture",manifest_sha256="fixture"),
 at("previous_pointer.json"),auto_unbox=TRUE)
invoke(c("scripts/updater/experimental_w01_fast/run_full_incremental_update.R",
 "--phase","canonical","--reviewed-root",at("valid_repair"),
 "--delta-writer","direct","--metadata",at("meta.csv"),
 "--prior-map",at("oldmap.csv"),"--previous-decisions",at("old.csv"),
 "--source-manifest",at("source_manifest.json"),
 "--current-seed-root",at("current_seed"),
 "--prior-canonical",at("previous","canonical","records.jsonl"),
 "--previous-root",at("previous"),"--previous-pointer",at("previous_pointer.json"),
 "--strip-actions",at("strips.jsonl"),"--repairs",at("original_repairs.jsonl"),
 "--output-dir",at("fast")))
final_path<-at("fast","production_canonical","records.jsonl")
replayed_path<-at("fast","replayed","canonical","records.jsonl")
stopifnot(file.exists(final_path),file.exists(replayed_path),
 identical(digest(file=final_path,algo="sha256"),
 digest(file=replayed_path,algo="sha256")))
final_records<-lapply(readLines(final_path),fromJSON,simplifyVector=FALSE)
stopifnot(length(final_records)==1L,
 identical(final_records[[1]]$canonical$title,"Corrected title"))
cat("PASS: verified Shiny human repair through actual Fast canonical continuation and replay\\n")
