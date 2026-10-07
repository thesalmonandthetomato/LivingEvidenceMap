#!/usr/bin/env Rscript
suppressPackageStartupMessages({library(httr2);library(jsonlite);library(digest)})

args<-commandArgs(trailingOnly=TRUE)
arg<-function(flag,default=NULL){i<-match(flag,args);if(is.na(i))return(default);if(i==length(args))stop(sprintf("Missing value after %s",flag),call.=FALSE);args[[i+1L]]}
corrections<-arg("--corrections");manifest<-arg("--manifest");output<-arg("--output");repository<-arg("--repository");source_run_id<-arg("--source-run-id")
if(any(vapply(list(corrections,manifest,output,repository,source_run_id),is.null,logical(1))))stop("Required arguments missing",call.=FALSE)
for(p in c(corrections,manifest))if(!file.exists(p))stop(sprintf("Missing file: %s",p),call.=FALSE)

m<-fromJSON(manifest,simplifyVector=FALSE)
if(!identical(m$status,"PASS"))stop("Correction manifest not PASS",call.=FALSE)
if(!identical(tolower(as.character(m$corrections_sha256)),tolower(digest(file=corrections,algo="sha256",serialize=FALSE))))stop("Correction SHA mismatch",call.=FALSE)

token<-Sys.getenv("ZENODO_ACCESS_TOKEN");if(!nzchar(token))stop("ZENODO_ACCESS_TOKEN is not set",call.=FALSE)
dir.create(dirname(output),recursive=TRUE,showWarnings=FALSE)
api<-"https://zenodo.org/api/deposit/depositions"
auth<-function(req)req|>req_headers(Authorization=paste("Bearer",token))
perform<-function(req,expected,label,timeout=600){
 resp<-req|>req_timeout(timeout)|>req_error(is_error=function(resp)FALSE)|>req_perform();st<-resp_status(resp)
 if(!(st%in%expected)){body<-tryCatch(resp_body_string(resp),error=function(e)"");stop(sprintf("Zenodo %s HTTP %d: %s",label,st,body),call.=FALSE)}
 resp
}
meta<-list(metadata=list(
 title=sprintf("Living Evidence Map W04 human abstract corrections | resume run %s",source_run_id),
 upload_type="dataset",publication_date=format(Sys.Date(),"%Y-%m-%d"),
 description=paste0("<p>Restricted preservation bundle of human-entered abstract corrections from Workflow 04 Shiny adjudication.</p>",
 "<p>Corrections are recoverable by normalized DOI where available and otherwise by unique normalized title. ",
 "The bundle is preserved separately so corrections to records excluded at W04 are not lost.</p>"),
 creators=list(list(name="Haddaway, Neal")),access_right="restricted",
 access_conditions="Contains human-entered bibliographic abstract corrections and provenance.",
 keywords=list("Living Evidence Map","Workflow 04","human adjudication","abstract correction",paste0("W04-resume-",source_run_id))
))
created<-perform(request(api)|>req_method("POST")|>auth()|>req_headers("Content-Type"="application/json")|>req_body_raw(charToRaw("{}"),type="application/json"),201L,"draft creation",60)|>resp_body_json(simplifyVector=FALSE)
dep_id<-as.character(created$id);bucket<-as.character(created$links$bucket)
perform(request(paste0(api,"/",dep_id))|>req_method("PUT")|>auth()|>req_headers("Content-Type"="application/json")|>req_body_json(meta,auto_unbox=TRUE),200L,"metadata update",60)
uploaded<-list()
for(p in c(corrections,manifest)){
 fn<-basename(p)
 resp<-request(paste0(bucket,"/",URLencode(fn,reserved=TRUE)))|>req_method("PUT")|>auth()|>req_headers(Expect="")|>req_body_file(p)|>req_timeout(1800)|>req_error(is_error=function(resp)FALSE)|>req_perform()
 if(!resp_status(resp)%in%c(200L,201L))stop(sprintf("Upload failed for %s HTTP %d",fn,resp_status(resp)),call.=FALSE)
 z<-resp_body_json(resp,simplifyVector=FALSE)
 uploaded[[fn]]<-list(bytes=unname(file.info(p)$size),sha256=digest(file=p,algo="sha256",serialize=FALSE),zenodo_checksum=z$checksum)
}
published<-perform(request(paste0(api,"/",dep_id,"/actions/publish"))|>req_method("POST")|>auth(),c(200L,201L,202L),"publish",120)|>resp_body_json(simplifyVector=FALSE)
record_id<-as.character(if(is.null(published$record_id))published$id else published$record_id)
receipt<-list(
 schema="living-evidence-map-w04-human-abstract-corrections-pointer-v1",
 status="published",source_w04_resume_run_id=as.character(source_run_id),
 corrections=as.integer(m$corrections),with_doi=as.integer(m$with_doi),title_fallback=as.integer(m$title_fallback),
 identity_rule=as.character(m$identity_rule),corrections_sha256=as.character(m$corrections_sha256),
 zenodo_record_id=record_id,doi=if(is.null(published$doi))NULL else published$doi,
 record_url=if(!is.null(published$links$html))published$links$html else paste0("https://zenodo.org/records/",record_id),
 visibility="restricted",files=uploaded,published_at_utc=format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ")
)
writeLines(toJSON(receipt,auto_unbox=TRUE,pretty=TRUE,null="null"),output,useBytes=TRUE)
cat(sprintf("PASS: published restricted W04 human abstract corrections as Zenodo record %s\n",record_id))
