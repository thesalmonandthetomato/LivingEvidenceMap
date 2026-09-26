#!/usr/bin/env Rscript
suppressPackageStartupMessages({library(httr2);library(jsonlite);library(digest)})

args<-commandArgs(trailingOnly=TRUE)
arg<-function(flag,default=NULL){i<-match(flag,args);if(is.na(i))return(default);if(i==length(args))stop(sprintf("Missing value after %s",flag),call.=FALSE);args[[i+1L]]}
state_dir<-normalizePath(arg("--state-dir"),mustWork=TRUE)
source_run_id<-arg("--source-run-id")
publication_run_id<-arg("--publication-run-id")
repository<-arg("--repository")
output_dir<-arg("--output-dir")
upstream_lean_sha<-tolower(arg("--upstream-lean-sha256",""))
upstream_w03_sha<-tolower(arg("--upstream-workflow03-sha256",""))
prompt_sha<-tolower(arg("--prompt-sha256",""))
if(any(vapply(list(source_run_id,publication_run_id,repository,output_dir),is.null,logical(1))))stop("Required publication arguments missing",call.=FALSE)
if(!nzchar(upstream_lean_sha)||!nzchar(upstream_w03_sha)||!nzchar(prompt_sha))stop("Upstream/prompt SHA values required",call.=FALSE)

layer_path<-file.path(state_dir,"workflow04_final_screening_layer.jsonl")
inc_path<-file.path(state_dir,"workflow04_included_record_ids.txt")
exc_path<-file.path(state_dir,"workflow04_excluded_record_ids.txt")
summary_path<-file.path(state_dir,"summary.json")
agree_path<-file.path(state_dir,"workflow04_agreement_summary.json")
for(p in c(layer_path,inc_path,exc_path,summary_path,agree_path))if(!file.exists(p))stop(sprintf("Missing Workflow 04 state file: %s",basename(p)),call.=FALSE)

s<-fromJSON(summary_path,simplifyVector=FALSE)
if(!identical(s$status,"PASS"))stop("Workflow 04 summary is not PASS",call.=FALSE)
if(as.integer(s$workflow03_eligible)!=32283L||as.integer(s$final_retain)!=19407L||as.integer(s$final_exclude)!=12876L||as.integer(s$unresolved)!=0L)stop("Workflow 04 final counts do not match validated baseline",call.=FALSE)

layer_lines<-readLines(layer_path,warn=FALSE,encoding="UTF-8");layer_lines<-layer_lines[nzchar(trimws(layer_lines))]
inc<-readLines(inc_path,warn=FALSE,encoding="UTF-8");inc<-inc[nzchar(trimws(inc))]
exc<-readLines(exc_path,warn=FALSE,encoding="UTF-8");exc<-exc[nzchar(trimws(exc))]
if(length(layer_lines)!=32283L||length(inc)!=19407L||length(exc)!=12876L)stop("Workflow 04 state cardinality invariant failed",call.=FALSE)
if(anyDuplicated(inc)||anyDuplicated(exc)||length(intersect(inc,exc))>0L)stop("Included/excluded ID partition invariant failed",call.=FALSE)
layer_ids<-vapply(layer_lines,function(z)as.character(fromJSON(z,simplifyVector=FALSE)$record_id),character(1))
if(any(!nzchar(layer_ids))||anyDuplicated(layer_ids)||!setequal(layer_ids,c(inc,exc)))stop("Workflow 04 layer identity invariant failed",call.=FALSE)

layer_sha<-digest(file=layer_path,algo="sha256",serialize=FALSE)
inc_sha<-digest(file=inc_path,algo="sha256",serialize=FALSE)
exc_sha<-digest(file=exc_path,algo="sha256",serialize=FALSE)
summary_sha<-digest(file=summary_path,algo="sha256",serialize=FALSE)
agree_sha<-digest(file=agree_path,algo="sha256",serialize=FALSE)

token<-Sys.getenv("ZENODO_ACCESS_TOKEN");if(!nzchar(token))stop("ZENODO_ACCESS_TOKEN is not set",call.=FALSE)
dir.create(output_dir,recursive=TRUE,showWarnings=FALSE);output_dir<-normalizePath(output_dir,mustWork=TRUE)
archive_dir<-file.path(output_dir,"archive_files");dir.create(archive_dir,recursive=TRUE,showWarnings=FALSE)

all_paths<-list.files(state_dir,recursive=TRUE,full.names=TRUE,all.files=TRUE,no..=TRUE)
if(length(all_paths))suppressWarnings(Sys.setFileTime(all_paths,as.POSIXct("2000-01-01",tz="UTC")))
archive_name<-sprintf("LivingEvidenceMap_workflow04_run-%s_screening_state.tar.gz",source_run_id)
archive_path<-file.path(archive_dir,archive_name)
old<-setwd(dirname(state_dir));on.exit(setwd(old),add=TRUE)
utils::tar(archive_path,files=basename(state_dir),compression="gzip",tar="internal")
setwd(old);on.exit(NULL,add=FALSE)
if(!file.exists(archive_path)||file.info(archive_path)$size<=0)stop("Failed to create Workflow 04 archive",call.=FALSE)

manifest<-list(
 schema="living-evidence-map-workflow04-screening-archive-v1",
 workflow="04",state="relevance_screening",
 source_github_run_id=as.character(source_run_id),publication_github_run_id=as.character(publication_run_id),
 source_github_run_url=sprintf("https://github.com/%s/actions/runs/%s",repository,source_run_id),repository=repository,
 upstream_lean_canonical_sha256=upstream_lean_sha,upstream_workflow03_publication_status_sha256=upstream_w03_sha,
 prompt_sha256=prompt_sha,records=32283L,retained=19407L,excluded=12876L,unresolved=0L,inclusion_rate=19407/32283,
 workflow04_final_screening_layer_sha256=layer_sha,included_record_ids_sha256=inc_sha,excluded_record_ids_sha256=exc_sha,
 summary_sha256=summary_sha,agreement_summary_sha256=agree_sha,file_visibility="restricted",
 files=list(state_archive=list(filename=archive_name,bytes=unname(file.info(archive_path)$size),sha256=digest(file=archive_path,algo="sha256",serialize=FALSE)))
)
manifest_name<-sprintf("LivingEvidenceMap_workflow04_run-%s_manifest.json",source_run_id)
manifest_path<-file.path(archive_dir,manifest_name)
writeLines(toJSON(manifest,auto_unbox=TRUE,pretty=TRUE,null="null",na="null",digits=NA),manifest_path,useBytes=TRUE)

api<-"https://zenodo.org/api/deposit/depositions"
auth<-function(req)req|>req_headers(Authorization=paste("Bearer",token))
perform<-function(req,expected,label,timeout=600){
 resp<-req|>req_timeout(timeout)|>req_error(is_error=function(resp)FALSE)|>req_perform();st<-resp_status(resp)
 if(!(st%in%expected)){body<-tryCatch(resp_body_string(resp),error=function(e)"");stop(sprintf("Zenodo %s HTTP %d: %s",label,st,body),call.=FALSE)}
 resp
}
metadata<-list(metadata=list(
 title=sprintf("Living Evidence Map Workflow 04 relevance-screening state | run %s",source_run_id),
 upload_type="dataset",publication_date=format(Sys.Date(),"%Y-%m-%d"),
 description=paste0("<p>Sparse relevance-screening state for Living Evidence Map Workflow 04.</p>",
 "<p>The state is keyed by stable canonical record_id and layers screening decisions over the exact Workflow 03 state rather than duplicating the canonical bibliographic database.</p>",
 "<p>Eligible records: 32,283; retained: 19,407; excluded: 12,876; unresolved: 0.</p>"),
 creators=list(list(name="Haddaway, Neal")),access_right="restricted",
 access_conditions="Files contain bibliographic identifiers, screening decisions and model-derived screening provenance.",
 keywords=list("Living Evidence Map","Workflow 04","relevance screening","evidence synthesis",paste0("LivingEvidenceMap-workflow04-run-",source_run_id))
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
  if(!(st%in%c(429L,500L,502L,503L,504L))||attempt==5L)stop(sprintf("Workflow 04 upload failed for %s HTTP %d",fn,st),call.=FALSE)
  Sys.sleep(min(60,5*2^(attempt-1L)))
 }
 uploaded[[i]]<-resp_body_json(ok,simplifyVector=FALSE)
}
published<-perform(request(paste0(api,"/",dep_id,"/actions/publish"))|>req_method("POST")|>auth(),c(200L,201L,202L),"publish",120)|>resp_body_json(simplifyVector=FALSE)
record_id<-as.character(if(is.null(published$record_id))published$id else published$record_id)
receipt<-c(manifest,list(
 status="published",zenodo_record_id=record_id,zenodo_deposition_id=dep_id,
 doi=if(is.null(published$doi))NA_character_ else published$doi,
 record_url=if(!is.null(published$links$html))published$links$html else paste0("https://zenodo.org/records/",record_id),
 visibility="restricted",
 archive_files=lapply(seq_along(paths),function(i){p<-paths[[i]];z<-uploaded[[i]];list(filename=basename(p),bytes=unname(file.info(p)$size),sha256=digest(file=p,algo="sha256",serialize=FALSE),zenodo_checksum=if(is.null(z$checksum))NULL else z$checksum)}),
 manifest_sha256=digest(file=manifest_path,algo="sha256",serialize=FALSE),
 published_at_utc=format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ")
))
writeLines(toJSON(receipt,auto_unbox=TRUE,pretty=TRUE,null="null",na="null",digits=NA),file.path(output_dir,"zenodo_receipt.json"),useBytes=TRUE)
cat(sprintf("PASS: published restricted Workflow 04 screening state as Zenodo record %s; retained=%d excluded=%d\n",record_id,19407L,12876L))
