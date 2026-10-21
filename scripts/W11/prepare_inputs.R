#!/usr/bin/env Rscript
suppressPackageStartupMessages(library(jsonlite))
suppressPackageStartupMessages(library(httr2))
id<-Sys.getenv("CANONICAL_DEPOSIT");token<-Sys.getenv("ZENODO_ACCESS_TOKEN")
if(!grepl("^[0-9]+$",id)) stop("Specify numeric canonical Zenodo deposit ID")
if(!nzchar(token)) stop("Missing ZENODO_ACCESS_TOKEN")
out<-"outputs/W11/inputs";dir.create(out,recursive=TRUE,showWarnings=FALSE)
r<-req_perform(request(paste0("https://zenodo.org/api/deposit/depositions/",id)) |>
 req_headers(Authorization=paste("Bearer",token)) |> req_timeout(40))
d<-fromJSON(resp_body_string(r),simplifyVector=FALSE)
fs<-d$files
if(!length(fs)) stop("Canonical deposit has no files")
names<-vapply(fs,function(z) as.character(z$filename),character(1))
candidates<-which(grepl("\\.zip$",names,ignore.case=TRUE)|grepl("records\\.jsonl$",names,ignore.case=TRUE))
if(length(candidates)!=1L) stop("Ambiguous canonical deposit files: ",paste(names,collapse=", "))
f<-fs[[candidates]]
dest<-tempfile(fileext=if(grepl("\\.zip$",names[candidates])) ".zip" else ".jsonl")
req_perform(request(f$links$download) |> req_headers(Authorization=paste("Bearer",token)) |>
 req_timeout(900) |> req_retry(max_tries=3),path=dest)
dir.create(file.path(out,"canonical"),recursive=TRUE,showWarnings=FALSE)
target<-file.path(out,"canonical/records.jsonl")
if(grepl("\\.zip$",names[candidates],ignore.case=TRUE)) {
 z<-unzip(dest,list=TRUE)
 candidates2<-z$Name[grepl("(^|/)canonical/records\\.jsonl$|^records\\.jsonl$",z$Name)]
 if(length(candidates2)!=1L) stop("Archive must contain exactly one canonical/records.jsonl: ",paste(candidates2,collapse=","))
 root<-tempfile("w11-canonical-");dir.create(root)
 unzip(dest,files=candidates2,exdir=root)
 file.copy(file.path(root,candidates2),target,overwrite=TRUE)
} else file.copy(dest,target,overwrite=TRUE)
stopifnot(file.exists(target),file.info(target)$size>0)
# Pin fulltexttest's completed historical audit by immutable commit, not its moving main branch.
manifest_url<-"https://raw.githubusercontent.com/thesalmonandthetomato/fulltexttest/b818ffa7965ea3915dbd97bd8c8ada49db9b5187/audit_results/historical_fulltext_doi_log_39_batches.csv"
# Batch 39 was separately recovered and can be supplied as a fixed artifact; do not claim completeness otherwise.
stop("STOP: historical 40-batch input must be pinned to an immutable, consolidated artifact before W11 ledger execution. No partial ledger produced.")
