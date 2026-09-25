#!/usr/bin/env Rscript
suppressPackageStartupMessages({library(httr2);library(jsonlite);library(digest)})

args<-commandArgs(trailingOnly=TRUE)
arg<-function(flag,default=NULL){i<-match(flag,args);if(is.na(i))return(default);if(i==length(args))stop(sprintf("Missing value after %s",flag),call.=FALSE);args[[i+1L]]}
state_dir<-normalizePath(arg("--state-dir"),mustWork=TRUE)
run_id<-arg("--run-id");repository<-arg("--repository");output_dir<-arg("--output-dir")
workflow01_sha<-arg("--workflow01-canonical-sha256");previous_pointer<-arg("--previous-pointer")
input_sha<-arg("--input-canonical-sha256");output_sha<-arg("--output-canonical-sha256")
if(any(vapply(list(run_id,repository,output_dir,workflow01_sha,previous_pointer,input_sha,output_sha),is.null,logical(1)))) stop("Missing required argument",call.=FALSE)
if(!file.exists(previous_pointer)) stop("Previous Workflow 02 pointer not found",call.=FALSE)
prev<-fromJSON(previous_pointer,simplifyVector=FALSE)
if(!identical(prev$status,"published")||!identical(prev$workflow,"02")) stop("Invalid previous Workflow 02 pointer",call.=FALSE)
patch_path<-file.path(state_dir,"canonical_corrections.jsonl")
audit_path<-file.path(state_dir,"decision_audit.jsonl")
report_path<-file.path(state_dir,"correction_report.json")
if(!all(file.exists(c(patch_path,audit_path,report_path)))) stop("Correction state is incomplete",call.=FALSE)
token<-Sys.getenv("ZENODO_ACCESS_TOKEN");if(!nzchar(token))stop("ZENODO_ACCESS_TOKEN is not set",call.=FALSE)
dir.create(output_dir,recursive=TRUE,showWarnings=FALSE);output_dir<-normalizePath(output_dir,mustWork=TRUE)
archive_dir<-file.path(output_dir,"archive_files");dir.create(archive_dir,recursive=TRUE,showWarnings=FALSE)
all_paths<-list.files(state_dir,recursive=TRUE,full.names=TRUE,all.files=TRUE,no..=TRUE)
if(length(all_paths)) suppressWarnings(Sys.setFileTime(all_paths,as.POSIXct("2000-01-01",tz="UTC")))
archive_name<-sprintf("LivingEvidenceMap_workflow02_run-%s_canonical_corrections.tar.gz",run_id)
archive_path<-file.path(archive_dir,archive_name)
old<-setwd(dirname(state_dir));on.exit(setwd(old),add=TRUE)
utils::tar(archive_path,files=basename(state_dir),compression="gzip",tar="internal")
setwd(old);on.exit(NULL,add=FALSE)
patch_lines<-readLines(patch_path,warn=FALSE,encoding="UTF-8");patch_lines<-patch_lines[nzchar(trimws(patch_lines))]
audit_lines<-readLines(audit_path,warn=FALSE,encoding="UTF-8");audit_lines<-audit_lines[nzchar(trimws(audit_lines))]
run_url<-sprintf("https://github.com/%s/actions/runs/%s",repository,run_id)
manifest<-list(
 schema="living-evidence-map-workflow02-canonical-correction-state-v1",
 workflow="02",state="canonical_correction_patch",github_run_id=as.character(run_id),
 github_run_url=run_url,repository=repository,
 upstream_workflow01_canonical_sha256=workflow01_sha,
 previous_workflow02=list(github_run_id=as.character(prev$github_run_id),zenodo_record_id=as.character(prev$zenodo_record_id),manifest_sha256=as.character(prev$manifest_sha256)),
 input_canonical_sha256=input_sha,output_canonical_sha256=output_sha,
 cumulative_patch_records=length(patch_lines),decision_audit_records=length(audit_lines),
 file_visibility="restricted",
 files=list(state_archive=list(filename=archive_name,bytes=unname(file.info(archive_path)$size),sha256=digest(file=archive_path,algo="sha256",serialize=FALSE)))
)
manifest_name<-sprintf("LivingEvidenceMap_workflow02_run-%s_manifest.json",run_id)
manifest_path<-file.path(archive_dir,manifest_name)
writeLines(toJSON(manifest,auto_unbox=TRUE,pretty=TRUE,null="null",na="null"),manifest_path,useBytes=TRUE)

api<-"https://zenodo.org/api/deposit/depositions";auth<-function(req)req|>req_headers(Authorization=paste("Bearer",token))
perform<-function(req,expected,label,timeout=600){resp<-req|>req_timeout(timeout)|>req_error(is_error=function(resp)FALSE)|>req_perform();st<-resp_status(resp);if(!(st%in%expected)){body<-tryCatch(resp_body_string(resp),error=function(e)"");stop(sprintf("Zenodo %s HTTP %d: %s",label,st,body),call.=FALSE)};resp}
metadata<-list(metadata=list(
 title=sprintf("Living Evidence Map Workflow 02 canonical correction state | run %s",run_id),
 upload_type="dataset",publication_date=format(Sys.Date(),"%Y-%m-%d"),
 description=paste0("<p>Sparse one-off canonical correction layer for Living Evidence Map Workflow 02.</p>",
 "<p>This record contains only changed title/abstract fields and the associated decision audit. It does not duplicate the canonical corpus.</p>",
 "<p>Input canonical SHA-256: <code>",input_sha,"</code>.</p><p>Output canonical SHA-256: <code>",output_sha,"</code>.</p>"),
 creators=list(list(name="Haddaway, Neal")),access_right="restricted",
 access_conditions="Files contain bibliographic metadata and provider-derived enrichment whose redistribution may be restricted by source terms.",
 keywords=list("Living Evidence Map","Workflow 02","canonical corrections","sparse patch",paste0("LivingEvidenceMap-workflow02-run-",run_id))
))
created<-perform(request(api)|>req_method("POST")|>auth()|>req_headers("Content-Type"="application/json")|>req_body_raw(charToRaw("{}"),type="application/json"),201L,"draft creation",60)|>resp_body_json(simplifyVector=FALSE)
dep_id<-as.character(created$id);bucket<-as.character(created$links$bucket)
perform(request(paste0(api,"/",dep_id))|>req_method("PUT")|>auth()|>req_headers("Content-Type"="application/json")|>req_body_json(metadata,auto_unbox=TRUE),200L,"metadata update",60)
paths<-c(archive_path,manifest_path);uploaded<-vector("list",length(paths))
for(i in seq_along(paths)){p<-paths[[i]];fn<-basename(p);ok<-NULL;for(attempt in seq_len(5L)){resp<-request(paste0(bucket,"/",URLencode(fn,reserved=TRUE)))|>req_method("PUT")|>auth()|>req_headers(Expect="")|>req_body_file(p)|>req_timeout(1800)|>req_error(is_error=function(resp)FALSE)|>req_perform();st<-resp_status(resp);if(st%in%c(200L,201L)){ok<-resp;break};if(!(st%in%c(429L,500L,502L,503L,504L))||attempt==5L)stop(sprintf("Upload failed for %s HTTP %d",fn,st),call.=FALSE);Sys.sleep(min(60,5*2^(attempt-1L)))};uploaded[[i]]<-resp_body_json(ok,simplifyVector=FALSE)}
published<-perform(request(paste0(api,"/",dep_id,"/actions/publish"))|>req_method("POST")|>auth(),c(200L,201L,202L),"publish",120)|>resp_body_json(simplifyVector=FALSE)
record_id<-as.character(if(is.null(published$record_id))published$id else published$record_id)
receipt<-list(
 status="published",workflow="02",state="canonical_correction_patch",github_run_id=as.character(run_id),github_run_url=run_url,
 upstream_workflow01_canonical_sha256=workflow01_sha,
 previous_workflow02=list(github_run_id=as.character(prev$github_run_id),zenodo_record_id=as.character(prev$zenodo_record_id),manifest_sha256=as.character(prev$manifest_sha256)),
 input_canonical_sha256=input_sha,output_canonical_sha256=output_sha,cumulative_patch_records=length(patch_lines),
 zenodo_record_id=record_id,zenodo_deposition_id=dep_id,doi=if(is.null(published$doi))NA_character_ else published$doi,
 record_url=if(!is.null(published$links$html))published$links$html else paste0("https://zenodo.org/records/",record_id),
 visibility="restricted",
 archive_files=lapply(seq_along(paths),function(i){p<-paths[[i]];z<-uploaded[[i]];list(filename=basename(p),bytes=unname(file.info(p)$size),sha256=digest(file=p,algo="sha256",serialize=FALSE),zenodo_checksum=if(is.null(z$checksum))NULL else z$checksum)}),
 manifest_sha256=digest(file=manifest_path,algo="sha256",serialize=FALSE),
 published_at_utc=format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ")
)
writeLines(toJSON(receipt,auto_unbox=TRUE,pretty=TRUE,null="null",na="null"),file.path(output_dir,"zenodo_receipt.json"),useBytes=TRUE)
cat(sprintf("PASS: published restricted Workflow 02 canonical correction state as Zenodo record %s; patch records=%d\n",record_id,length(patch_lines)))
