#!/usr/bin/env Rscript
suppressPackageStartupMessages({library(httr2);library(jsonlite);library(digest)})

args<-commandArgs(trailingOnly=TRUE)
`%||%`<-function(x,y)if(is.null(x))y else x
arg<-function(flag,default=NULL){i<-match(flag,args);if(is.na(i))return(default);if(i==length(args))stop(sprintf("Missing value after %s",flag),call.=FALSE);args[[i+1L]]}
state_dir<-normalizePath(arg("--state-dir"),mustWork=TRUE)
source_run_id<-arg("--source-run-id");source_commit<-arg("--source-commit");publication_run_id<-arg("--publication-run-id")
repository<-arg("--repository");output_dir<-arg("--output-dir")
upstream_w06_record_id<-arg("--upstream-w06-record-id");upstream_w06_layer_sha<-tolower(arg("--upstream-w06-layer-sha256",""))
if(any(vapply(list(source_run_id,source_commit,publication_run_id,repository,output_dir,upstream_w06_record_id),is.null,logical(1))))stop("Required W07 publication arguments missing",call.=FALSE)
if(!nzchar(upstream_w06_layer_sha))stop("Upstream W06 layer SHA required",call.=FALSE)

paths<-list(
 records=file.path(state_dir,"workflow07_records.csv"),
 scores=file.path(state_dir,"workflow07_topic_pathway_scores.csv"),
 record_summary=file.path(state_dir,"workflow07_topic_record_summary.csv"),
 zero=file.path(state_dir,"workflow07_zero_topic_targeted_rescreen.jsonl"),
 retained=file.path(state_dir,"workflow07_topic_pathway_scores_retained.csv"),
 qc=file.path(state_dir,"workflow07_topic_record_qc.csv"),
 human=file.path(state_dir,"workflow07_workflow08_human_review_queue.csv"),
 late=file.path(state_dir,"workflow07_late_automatic_exclusions.csv"),
 uncoded=file.path(state_dir,"workflow07_included_uncoded.csv"),
 high=file.path(state_dir,"workflow07_high_topic_automated_qc.csv"),
 qc_summary=file.path(state_dir,"workflow07_qc_summary.json"),
 complete_manifest=file.path(state_dir,"workflow07_topic_complete_manifest.json"),
 ontology=file.path(state_dir,"topic_ontology_v3_6.csv"),
 prompt=file.path(state_dir,"topic_system_prompt_v3_6.txt")
)
for(p in paths)if(!file.exists(p))stop(sprintf("Missing W07 state file: %s",basename(p)),call.=FALSE)

records<-read.csv(paths$records,stringsAsFactors=FALSE,check.names=FALSE)
scores<-read.csv(paths$scores,stringsAsFactors=FALSE,check.names=FALSE)
rs<-read.csv(paths$record_summary,stringsAsFactors=FALSE,check.names=FALSE)
qc<-read.csv(paths$qc,stringsAsFactors=FALSE,check.names=FALSE)
qcs<-fromJSON(paths$qc_summary,simplifyVector=FALSE)
cm<-fromJSON(paths$complete_manifest,simplifyVector=FALSE)
if(!nrow(records)||anyDuplicated(records$record_id)||!setequal(records$record_id,rs$record_id)||!setequal(records$record_id,qc$record_id))stop("W07 state identity invariant failed",call.=FALSE)
if(anyDuplicated(scores[,c("record_id","path_id")]))stop("W07 score identity invariant failed",call.=FALSE)
if(as.integer(cm$records)!=nrow(records)||as.integer(qcs$records)!=nrow(records))stop("W07 manifest record count mismatch",call.=FALSE)

ontology_sha<-digest(file=paths$ontology,algo="sha256",serialize=FALSE)
prompt_sha<-digest(file=paths$prompt,algo="sha256",serialize=FALSE)
if(!identical(tolower(as.character(cm$ontology_sha256)),tolower(ontology_sha))||!identical(tolower(as.character(cm$prompt_sha256)),tolower(prompt_sha)))stop("W07 ontology/prompt checksum mismatch",call.=FALSE)

sha<-lapply(paths,function(p)digest(file=p,algo="sha256",serialize=FALSE))
token<-Sys.getenv("ZENODO_ACCESS_TOKEN");if(!nzchar(token))stop("ZENODO_ACCESS_TOKEN not set",call.=FALSE)
dir.create(output_dir,recursive=TRUE,showWarnings=FALSE);output_dir<-normalizePath(output_dir,mustWork=TRUE)
archive_dir<-file.path(output_dir,"archive_files");dir.create(archive_dir,recursive=TRUE,showWarnings=FALSE)

all_paths<-list.files(state_dir,recursive=TRUE,full.names=TRUE,all.files=TRUE,no..=TRUE)
if(length(all_paths))suppressWarnings(Sys.setFileTime(all_paths,as.POSIXct("2000-01-01",tz="UTC")))
archive_name<-sprintf("LivingEvidenceMap_workflow07_run-%s_topic_state.tar.gz",source_run_id)
archive_path<-file.path(archive_dir,archive_name)
old<-setwd(dirname(state_dir));on.exit(setwd(old),add=TRUE)
utils::tar(archive_path,files=basename(state_dir),compression="gzip",tar="internal")
setwd(old);on.exit(NULL,add=FALSE)

manifest<-list(
 schema="living-evidence-map-workflow07-topic-archive-v1",workflow="07",state="topic_coding_and_qc",
 source_github_run_id=as.character(source_run_id),source_github_commit=as.character(source_commit),
 publication_github_run_id=as.character(publication_run_id),source_github_run_url=sprintf("https://github.com/%s/actions/runs/%s",repository,source_run_id),
 repository=repository,upstream_workflow06_zenodo_record_id=as.character(upstream_w06_record_id),
 upstream_workflow06_geography_layer_sha256=upstream_w06_layer_sha,
 records=nrow(records),raw_topic_assignments=nrow(scores),
 zero_topic_records=as.integer(qcs$zero_topic_records),included_uncoded_records=as.integer(qcs$included_uncoded_records),
 late_automatic_exclusions=as.integer(qcs$late_automatic_exclusions),
 human_adjudication_records=as.integer(qcs$immediate_human_adjudication_records),
 ontology_sha256=ontology_sha,prompt_sha256=prompt_sha,
 workflow07_records_sha256=sha$records,workflow07_topic_pathway_scores_sha256=sha$scores,
 workflow07_topic_record_summary_sha256=sha$record_summary,workflow07_zero_topic_rescreen_sha256=sha$zero,
 workflow07_topic_record_qc_sha256=sha$qc,workflow07_qc_summary_sha256=sha$qc_summary,
 file_visibility="restricted",
 files=list(state_archive=list(filename=archive_name,bytes=unname(file.info(archive_path)$size),sha256=digest(file=archive_path,algo="sha256",serialize=FALSE)))
)
manifest_path<-file.path(archive_dir,sprintf("LivingEvidenceMap_workflow07_run-%s_manifest.json",source_run_id))
writeLines(toJSON(manifest,auto_unbox=TRUE,pretty=TRUE,null="null",na="null",digits=NA),manifest_path,useBytes=TRUE)

api<-"https://zenodo.org/api/deposit/depositions";auth<-function(req)req|>req_headers(Authorization=paste("Bearer",token))
perform<-function(req,expected,label,timeout=600){resp<-req|>req_timeout(timeout)|>req_error(is_error=function(resp)FALSE)|>req_perform();st<-resp_status(resp);if(!(st%in%expected))stop(sprintf("Zenodo %s HTTP %d: %s",label,st,tryCatch(resp_body_string(resp),error=function(e)"")),call.=FALSE);resp}
metadata<-list(metadata=list(
 title=sprintf("Living Evidence Map Workflow 07 topic-coding state | run %s",source_run_id),
 upload_type="dataset",publication_date=format(Sys.Date(),"%Y-%m-%d"),
 description=paste0("<p>Durable sparse Workflow 07 topic-coding and QC state.</p><p>Records: ",nrow(records),"; raw topic assignments: ",nrow(scores),"; zero-topic records: ",qcs$zero_topic_records,"; late automatic exclusions: ",qcs$late_automatic_exclusions,"; human-adjudication records: ",qcs$immediate_human_adjudication_records,".</p>"),
 creators=list(list(name="Haddaway, Neal")),access_right="restricted",
 access_conditions="Files contain bibliographic record identifiers and model-derived topic coding provenance.",
 keywords=list("Living Evidence Map","Workflow 07","topic coding","evidence synthesis")
))
created<-perform(request(api)|>req_method("POST")|>auth()|>req_headers("Content-Type"="application/json")|>req_body_raw(charToRaw("{}"),type="application/json"),201L,"draft creation",60)|>resp_body_json(simplifyVector=FALSE)
dep_id<-as.character(created$id);bucket<-as.character(created$links$bucket)
perform(request(paste0(api,"/",dep_id))|>req_method("PUT")|>auth()|>req_headers("Content-Type"="application/json")|>req_body_json(metadata,auto_unbox=TRUE),200L,"metadata update",60)
upload_paths<-c(archive_path,manifest_path);uploaded<-vector("list",length(upload_paths))
for(i in seq_along(upload_paths)){p<-upload_paths[[i]];fn<-basename(p);resp<-request(paste0(bucket,"/",URLencode(fn,reserved=TRUE)))|>req_method("PUT")|>auth()|>req_headers(Expect="")|>req_body_file(p)|>req_timeout(1800)|>req_retry(max_tries=5)|>req_perform();uploaded[[i]]<-resp_body_json(resp,simplifyVector=FALSE)}
published<-perform(request(paste0(api,"/",dep_id,"/actions/publish"))|>req_method("POST")|>auth(),c(200L,201L,202L),"publish",120)|>resp_body_json(simplifyVector=FALSE)
record_id<-as.character(if(is.null(published$record_id))published$id else published$record_id)
receipt<-c(manifest,list(status="published",zenodo_record_id=record_id,zenodo_deposition_id=dep_id,
 doi=if(is.null(published$doi))NA_character_ else published$doi,
 record_url=if(!is.null(published$links$html))published$links$html else paste0("https://zenodo.org/records/",record_id),
 visibility="restricted",archive_files=lapply(seq_along(upload_paths),function(i){p<-upload_paths[[i]];z<-uploaded[[i]];list(filename=basename(p),bytes=unname(file.info(p)$size),sha256=digest(file=p,algo="sha256",serialize=FALSE),zenodo_checksum=z$checksum %||% NULL)}),
 manifest_sha256=digest(file=manifest_path,algo="sha256",serialize=FALSE),published_at_utc=format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ")))
writeLines(toJSON(receipt,auto_unbox=TRUE,pretty=TRUE,null="null",na="null",digits=NA),file.path(output_dir,"zenodo_receipt.json"),useBytes=TRUE)
cat(sprintf("PASS: published restricted Workflow 07 topic state as Zenodo record %s\n",record_id))
