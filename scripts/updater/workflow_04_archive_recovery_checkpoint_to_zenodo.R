#!/usr/bin/env Rscript
suppressPackageStartupMessages({library(httr2);library(jsonlite);library(digest)})

args<-commandArgs(trailingOnly=TRUE)
arg<-function(flag,default=NULL){i<-match(flag,args);if(is.na(i))return(default);if(i==length(args))stop(sprintf("Missing value after %s",flag),call.=FALSE);args[[i+1L]]}
state_dir<-normalizePath(arg("--state-dir"),mustWork=TRUE)
source_run_id<-arg("--source-run-id")
repository<-arg("--repository")
output_dir<-arg("--output-dir")
if(any(vapply(list(source_run_id,repository,output_dir),is.null,logical(1))))stop("Required: --state-dir --source-run-id --repository --output-dir",call.=FALSE)

report_path<-file.path(state_dir,"recovery_report.json")
salvage_path<-file.path(state_dir,"salvaged_new_pass1.jsonl")
if(!file.exists(report_path)||!file.exists(salvage_path))stop("Recovery state missing report or salvaged pass-1 file",call.=FALSE)
r<-fromJSON(report_path,simplifyVector=FALSE)
if(!identical(r$status,"PASS"))stop("Recovery report is not PASS",call.=FALSE)

token<-Sys.getenv("ZENODO_ACCESS_TOKEN");if(!nzchar(token))stop("ZENODO_ACCESS_TOKEN is not set",call.=FALSE)
dir.create(output_dir,recursive=TRUE,showWarnings=FALSE);output_dir<-normalizePath(output_dir,mustWork=TRUE)
archive_dir<-file.path(output_dir,"archive_files");dir.create(archive_dir,recursive=TRUE,showWarnings=FALSE)

all_paths<-list.files(state_dir,recursive=TRUE,full.names=TRUE,all.files=TRUE,no..=TRUE)
if(length(all_paths))suppressWarnings(Sys.setFileTime(all_paths,as.POSIXct("2000-01-01",tz="UTC")))
archive_name<-sprintf("LivingEvidenceMap_workflow04_cancelled_run-%s_recovery.tar.gz",source_run_id)
archive_path<-file.path(archive_dir,archive_name)
old<-setwd(dirname(state_dir));on.exit(setwd(old),add=TRUE)
utils::tar(archive_path,files=basename(state_dir),compression="gzip",tar="internal")
setwd(old);on.exit(NULL,add=FALSE)
if(!file.exists(archive_path)||file.info(archive_path)$size<=0)stop("Failed to create recovery archive",call.=FALSE)

manifest<-list(
  schema="living-evidence-map-workflow04-recovery-checkpoint-v1",
  workflow="04",
  state="cancelled_run_recovery_checkpoint",
  source_github_run_id=as.character(source_run_id),
  source_github_run_url=sprintf("https://github.com/%s/actions/runs/%s",repository,source_run_id),
  repository=repository,
  checkpoint_rows=as.integer(r$checkpoint_rows),
  salvaged_new_record_pass1_rows=as.integer(r$salvaged_new_record_pass1_rows),
  redundant_existing_record_pass1_rows=as.integer(r$redundant_existing_record_pass1_rows),
  prompt_sha256=as.character(r$prompt_sha256),
  model=as.character(r$model),
  salvage_sha256=digest(file=salvage_path,algo="sha256",serialize=FALSE),
  file_visibility="restricted",
  files=list(state_archive=list(filename=archive_name,bytes=unname(file.info(archive_path)$size),sha256=digest(file=archive_path,algo="sha256",serialize=FALSE)))
)
manifest_name<-sprintf("LivingEvidenceMap_workflow04_cancelled_run-%s_recovery_manifest.json",source_run_id)
manifest_path<-file.path(archive_dir,manifest_name)
writeLines(toJSON(manifest,auto_unbox=TRUE,pretty=TRUE,null="null",na="null"),manifest_path,useBytes=TRUE)

api<-"https://zenodo.org/api/deposit/depositions"
auth<-function(req)req|>req_headers(Authorization=paste("Bearer",token))
perform<-function(req,expected,label,timeout=600){
  resp<-req|>req_timeout(timeout)|>req_error(is_error=function(resp)FALSE)|>req_perform();st<-resp_status(resp)
  if(!(st%in%expected)){body<-tryCatch(resp_body_string(resp),error=function(e)"");stop(sprintf("Zenodo %s HTTP %d: %s",label,st,body),call.=FALSE)}
  resp
}
metadata<-list(metadata=list(
  title=sprintf("Living Evidence Map Workflow 04 recovery checkpoint | cancelled run %s",source_run_id),
  upload_type="dataset",publication_date=format(Sys.Date(),"%Y-%m-%d"),
  description=paste0("<p>Recovery checkpoint preserving completed Workflow 04 model decisions from cancelled GitHub Actions run ",source_run_id,".</p>",
    "<p>These are recovery inputs only, not an authoritative Workflow 04 final state. Checkpoint rows: ",as.integer(r$checkpoint_rows),
    "; reusable pass-1 rows for genuinely new records: ",as.integer(r$salvaged_new_record_pass1_rows),".</p>"),
  creators=list(list(name="Haddaway, Neal")),access_right="restricted",
  access_conditions="Files contain bibliographic identifiers and model-derived screening provenance retained solely for workflow recovery.",
  keywords=list("Living Evidence Map","Workflow 04","recovery checkpoint","screening",paste0("LivingEvidenceMap-workflow04-recovery-",source_run_id))
))
created<-perform(request(api)|>req_method("POST")|>auth()|>req_headers("Content-Type"="application/json")|>req_body_raw(charToRaw("{}"),type="application/json"),201L,"draft creation",60)|>resp_body_json(simplifyVector=FALSE)
dep_id<-as.character(created$id);bucket<-as.character(created$links$bucket)
perform(request(paste0(api,"/",dep_id))|>req_method("PUT")|>auth()|>req_headers("Content-Type"="application/json")|>req_body_json(metadata,auto_unbox=TRUE),200L,"metadata update",60)

paths<-c(archive_path,manifest_path);uploaded<-vector("list",length(paths))
for(i in seq_along(paths)){
  p<-paths[[i]];fn<-basename(p);ok<-NULL
  for(attempt in seq_len(5L)){
    resp<-request(paste0(bucket,"/",URLencode(fn,reserved=TRUE)))|>req_method("PUT")|>auth()|>req_headers(Expect="")|>req_body_file(p)|>req_timeout(1800)|>req_error(is_error=function(resp)FALSE)|>req_perform()
    st<-resp_status(resp)
    if(st%in%c(200L,201L)){ok<-resp;break}
    if(!(st%in%c(429L,500L,502L,503L,504L))||attempt==5L)stop(sprintf("Recovery upload failed for %s HTTP %d",fn,st),call.=FALSE)
    Sys.sleep(min(60,5*2^(attempt-1L)))
  }
  uploaded[[i]]<-resp_body_json(ok,simplifyVector=FALSE)
}
published<-perform(request(paste0(api,"/",dep_id,"/actions/publish"))|>req_method("POST")|>auth(),c(200L,201L,202L),"publish",120)|>resp_body_json(simplifyVector=FALSE)
record_id<-as.character(if(is.null(published$record_id))published$id else published$record_id)
receipt<-c(manifest,list(
  status="published",
  zenodo_record_id=record_id,zenodo_deposition_id=dep_id,
  doi=if(is.null(published$doi))NA_character_ else published$doi,
  record_url=if(!is.null(published$links$html))published$links$html else paste0("https://zenodo.org/records/",record_id),
  visibility="restricted",
  archive_files=lapply(seq_along(paths),function(i){p<-paths[[i]];z<-uploaded[[i]];list(filename=basename(p),bytes=unname(file.info(p)$size),sha256=digest(file=p,algo="sha256",serialize=FALSE),zenodo_checksum=if(is.null(z$checksum))NULL else z$checksum)}),
  manifest_sha256=digest(file=manifest_path,algo="sha256",serialize=FALSE),
  published_at_utc=format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ")
))
writeLines(toJSON(receipt,auto_unbox=TRUE,pretty=TRUE,null="null",na="null"),file.path(output_dir,"zenodo_receipt.json"),useBytes=TRUE)
cat(sprintf("PASS: published W04 recovery checkpoint as Zenodo record %s; salvaged new pass-1 rows=%d\n",record_id,as.integer(r$salvaged_new_record_pass1_rows)))
