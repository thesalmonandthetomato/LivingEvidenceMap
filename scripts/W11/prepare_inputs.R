#!/usr/bin/env Rscript
suppressPackageStartupMessages(library(jsonlite))
suppressPackageStartupMessages(library(httr2))
id<-Sys.getenv("CANONICAL_DEPOSIT")
tokens<-unique(Filter(nzchar,c(Sys.getenv("ZENODO_ACCESS_TOKEN"),Sys.getenv("ZENODO_TOKEN"))))
if(!grepl("^[0-9]+$",id)) stop("Specify numeric canonical Zenodo deposit ID")
if(!length(tokens)) stop("Missing both available Zenodo secrets")
fetch_deposit<-function(identifier) {
  endpoint<-paste0("https://zenodo.org/api/deposit/depositions/",identifier)
  for(candidate in tokens) {
    response<-tryCatch(req_perform(request(endpoint) |> req_headers(Authorization=paste("Bearer",candidate)) |> req_timeout(45)),error=function(e) NULL)
    if(!is.null(response)&&resp_status(response)<300) return(list(data=fromJSON(resp_body_string(response),simplifyVector=FALSE),token=candidate))
  }
  stop("No configured Zenodo token can access restricted deposit ",identifier," through depositions API")
}
out<-"outputs/W11/inputs";dir.create(out,recursive=TRUE,showWarnings=FALSE)
resolved<-fetch_deposit(id)
d<-resolved$data
token<-resolved$token
fs<-d$files
if(!length(fs)) stop("Canonical deposit has no files")
names<-vapply(fs,function(z) as.character(z$filename),character(1))
candidates<-which(grepl("workflow01.*(tar\\.gz|tgz)$",names,ignore.case=TRUE))
if(length(candidates)!=1L) stop("Expected one original Workflow 01 state tar.gz: ",paste(names,collapse=", "))
f<-fs[[candidates]]
dest<-tempfile(fileext=".tar.gz")
req_perform(request(f$links$download) |> req_headers(Authorization=paste("Bearer",token)) |>
 req_timeout(1500) |> req_retry(max_tries=3),path=dest)
dir.create(file.path(out,"canonical"),recursive=TRUE,showWarnings=FALSE)
target<-file.path(out,"canonical/records.jsonl")
members<-untar(dest,list=TRUE)
candidates2<-members[grepl("(^|/)canonical/records\\.jsonl$",members)]
if(length(candidates2)!=1L) stop("Archive must contain exactly one canonical/records.jsonl")
root<-tempfile("w11-canonical-");dir.create(root)
untar(dest,files=candidates2,exdir=root)
if(!file.copy(file.path(root,candidates2),target,overwrite=TRUE)) stop("Failed to stage canonical JSONL")

stopifnot(file.exists(target),file.info(target)$size>0)
# Pin fulltexttest's completed historical audit by immutable commit, not its moving main branch.
manifest_url<-"https://raw.githubusercontent.com/thesalmonandthetomato/fulltexttest/74d06e2c8a9b179f2ea35b221fd8510b7531264d/audit_results/historical_fulltext_doi_log_39_batches.csv"
manifest_file<-file.path(out,"historical_fulltext_all_records.csv")
req_perform(request(manifest_url) |> req_timeout(90) |> req_retry(max_tries=3),path=manifest_file)
m<-read.csv(manifest_file,stringsAsFactors=FALSE,check.names=FALSE,colClasses="character")
if(nrow(m)!=3835L) stop("Frozen 39-batch manifest row count mismatch")
# The original batch 39 archived 100 PDFs. Its retrieval manifest is inside the deposited ZIP.
id39<-"23021043"
resolved39<-fetch_deposit(id39)
d39<-resolved39$data
token39<-resolved39$token
fs39<-d39$files
if(length(fs39)!=1L) stop("Expected exactly one archived ZIP for batch 39")
nm39<-as.character(fs39[[1]]$filename)
if(!identical(nm39,"LivingEvidenceMap_fulltext_batch_039_run-36457592665.zip")) stop("Unexpected batch 39 archive: ",nm39)
zip39<-tempfile(fileext=".zip")
req_perform(request(fs39[[1]]$links$download) |> req_headers(Authorization=paste("Bearer",token39)) |>
 req_timeout(900) |> req_retry(max_tries=3),path=zip39)
z39<-unzip(zip39,list=TRUE)
if(sum(grepl("\\.pdf$",z39$Name,ignore.case=TRUE))!=100L) stop("Batch 39 PDF count mismatch")
mn<-z39$Name[grepl("(^|/)download_manifest\\.csv$",z39$Name)]
if(length(mn)!=1L) stop("Batch 39 missing unambiguous download manifest")
folder<-tempfile("batch39-");dir.create(folder)
unzip(zip39,files=mn,exdir=folder)
add<-read.csv(file.path(folder,mn),stringsAsFactors=FALSE,check.names=FALSE,colClasses="character")
if(nrow(add)!=100L||!all(add$format=="pdf")||!all(add$status=="downloaded")) stop("Batch 39 manifest mismatch")
add<-data.frame(batch=add$batch,github_run_id="36457592665",zenodo_deposit_id=id39,
 record_index=add$batch_position,doi=add$doi,openalex_id=add$openalex_id,
 format=add$format,source_url=add$url,status=add$status,bytes=add$bytes,
 sha256=add$sha256,filename=add$file,stringsAsFactors=FALSE)
if(!identical(names(m),names(add))) stop("Input schemas differ")
m<-rbind(m,add)
m<-m[order(as.integer(m$batch),as.integer(m$record_index)),,drop=FALSE]
if(nrow(m)!=3935L||anyDuplicated(paste(m$batch,m$record_index))) stop("Incorrect W11 retrieval manifest")
write.csv(m,manifest_file,row.names=FALSE,na="")
write_json(list(canonical_deposit=id,canonical_zip=names[candidates],canonical_path="canonical/records.jsonl",
 canonical_bytes=unname(file.info(target)$size),historical_retrieval_rows=nrow(m),
 source_39_batch_commit="74d06e2c8a9b179f2ea35b221fd8510b7531264d",
 batch_39_deposit_id=id39),file.path(out,"input_provenance.json"),pretty=TRUE,auto_unbox=TRUE)
cat("Staged ",nrow(m)," DOI retrieval rows and canonical snapshot\n")
