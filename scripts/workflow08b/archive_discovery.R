#!/usr/bin/env Rscript
# Archive an isolated W08b discovery checkpoint as restricted Zenodo data.
suppressPackageStartupMessages({library(jsonlite);library(httr2);library(digest)})
a<-commandArgs(trailingOnly=TRUE)
if(length(a)!=3L)stop("Usage: archive_discovery.R <discovery-dir> <run-id> <receipt.json>")
root<-normalizePath(a[[1]],mustWork=TRUE);run<-a[[2]];receipt<-a[[3]]
token<-Sys.getenv("ZENODO_ACCESS_TOKEN","")
if(!nzchar(token))stop("ZENODO_ACCESS_TOKEN absent")
state<-file.path(root,"discovery_summary.json")
ledger<-file.path(root,"lens_seed_status.jsonl")
if(!file.exists(state)||!file.exists(ledger))stop("Incomplete checkpoint directory")
info<-fromJSON(state,simplifyVector=FALSE)
if(!identical(info$schema,"workflow08b-lens-discovery-dev-v1"))stop("Unrecognised W08b state")
archive<-file.path(tempdir(),paste0("w08b-discovery-run-",run,".tar.gz"))
files<-list.files(root,recursive=TRUE,all.files=TRUE,no..=TRUE)
if(!length(files))stop("Empty checkpoint")
old<-setwd(root);on.exit(setwd(old),add=TRUE)
utils::tar(archive,files=files,compression="gzip",tar="internal")
setwd(old);on.exit(NULL,add=FALSE)
sha<-digest(file=archive,algo="sha256",serialize=FALSE)
api<-"https://zenodo.org/api/deposit/depositions"
auth<-function(r)req_headers(r,Authorization=paste("Bearer",token))
call<-function(r,allowed,label){
 x<-req_perform(req_error(req_timeout(r,120),is_error=function(resp)FALSE))
 if(!(resp_status(x)%in%allowed))stop("Zenodo ",label," HTTP ",resp_status(x),": ",substr(resp_body_string(x),1,600))
 x
}
created<-resp_body_json(call(auth(req_method(request(api),"POST")) |>
 req_body_raw(charToRaw("{}"),type="application/json"),201L,"draft create"),simplifyVector=FALSE)
id<-as.character(created$id); bucket<-as.character(created$links$bucket)
if(!nzchar(id)||!nzchar(bucket))stop("Invalid draft response")
metadata<-list(metadata=list(
 title=paste("Living Evidence Map W08b citation-discovery checkpoint | run",run),
 upload_type="dataset",publication_date=format(Sys.Date(),"%Y-%m-%d"),
 description="<p>Restricted W08b incremental citation-discovery checkpoint with seed statuses and provider-specific citation edges. Incomplete seeds remain retryable. Not a released evidence map.</p>",
 creators=list(list(name="Haddaway, Neal")),access_right="restricted",
 access_conditions="Derived citation edges and record identifiers from licensed scholarly metadata sources.",
 keywords=list("Living Evidence Map","citation chasing","W08b","checkpoint")))
call(auth(req_method(request(paste0(api,"/",id)),"PUT")) |> req_body_json(metadata,auto_unbox=TRUE),200L,"metadata")
fn<-basename(archive)
up<-auth(req_method(request(paste0(bucket,"/",URLencode(fn,reserved=TRUE))),"PUT")) |>
 req_headers(Expect="") |> req_body_file(archive) |> req_timeout(1800)
call(up,c(200L,201L),"upload")
pub<-resp_body_json(call(auth(req_method(request(paste0(api,"/",id,"/actions/publish")),"POST")),
 c(200L,201L,202L),"publish"),simplifyVector=FALSE)
record<-as.character(if(is.null(pub$record_id))pub$id else pub$record_id)
dir.create(dirname(receipt),recursive=TRUE,showWarnings=FALSE)
writeLines(toJSON(list(schema="workflow08b-discovery-checkpoint-v1",status="published",
 run_id=run,zenodo_record_id=record,sha256=sha,archive_filename=fn,
 requests=info$requests_this_execution,complete=info$complete_seeds,
 incomplete=info$incomplete_seeds),pretty=TRUE,auto_unbox=TRUE),receipt)
cat("PASS: archived W08b restricted checkpoint: Zenodo record ",record,"\n",sep="")
