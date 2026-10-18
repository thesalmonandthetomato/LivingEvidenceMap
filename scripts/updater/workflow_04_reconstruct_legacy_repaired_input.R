#!/usr/bin/env Rscript
# Exact reconstruction from historical W04 integrity-repair run 37679581307.
# The digest of the result is verified by the caller; never bypass that check.
dir.create("inputs/human_corrections",recursive=TRUE,showWarnings=FALSE)
library(jsonlite); library(httr2); library(digest)
p <- fromJSON(Sys.getenv('HUMAN_CORRECTIONS_POINTER'),simplifyVector=FALSE)
stopifnot(p$status=='published',p$visibility=='restricted',as.integer(p$corrections)==157L)
token <- Sys.getenv('ZENODO_ACCESS_TOKEN'); stopifnot(nzchar(token))
dep <- request(paste0('https://zenodo.org/api/deposit/depositions/',p$zenodo_record_id)) |>
  req_headers(Authorization=paste('Bearer',token)) |> req_timeout(120) |>
  req_perform() |> resp_body_json(simplifyVector=FALSE)
stopifnot(isTRUE(dep$submitted))
bucket <- sub('/$','',as.character(dep$links$bucket))
fn <- 'workflow04_human_abstract_corrections.jsonl'
dest <- file.path('inputs/human_corrections',fn)
resp <- request(paste0(bucket,'/',URLencode(fn,reserved=TRUE))) |>
  req_method('GET') |> req_headers(Authorization=paste('Bearer',token)) |>
  req_timeout(600) |> req_error(is_error=function(resp)FALSE) |> req_perform(path=dest)
stopifnot(resp_status(resp)==200L)
sha <- digest(file=dest,algo='sha256',serialize=FALSE)
stopifnot(tolower(sha)==tolower(as.character(p$corrections_sha256)))
cat('PASS: restored 157 protected W04 human abstract corrections\n')

suppressPackageStartupMessages(library(jsonlite))
`%||%` <- function(x,y) if(is.null(x)) y else x
scalar <- function(x){if(is.null(x)||!length(x))return('');z<-as.character(x[[1L]]);if(is.na(z))'' else trimws(gsub('[[:space:]]+',' ',z))}
norm_doi <- function(x){z<-tolower(scalar(x));if(!nzchar(z))return('');z<-sub('^https?://(dx\\.)?doi\\.org/','',z,perl=TRUE);z<-sub('^doi:\\s*','',z,perl=TRUE);z<-sub('[?#].*$','',z,perl=TRUE);z<-sub('\\.(html?|pdf|xml)$','',z,perl=TRUE,ignore.case=TRUE);sub('[.,;:]+$','',z,perl=TRUE)}
norm_title <- function(x)tolower(trimws(gsub('[[:space:]]+',' ',scalar(x))))
readjl <- function(p){x<-readLines(p,warn=FALSE,encoding='UTF-8');x<-x[nzchar(trimws(x))];lapply(x,function(z)fromJSON(z,simplifyVector=FALSE))}
recs <- readjl('inputs/current/canonical_lean.raw.jsonl')
corr <- readjl('inputs/human_corrections/workflow04_human_abstract_corrections.jsonl')
stopifnot(length(recs)==50440L,length(corr)==157L)
ids <- vapply(recs,function(r)scalar((r$identity%||%list())$record_id),character(1))
dois <- vapply(recs,function(r)norm_doi((r$canonical%||%list())$doi),character(1))
titles <- vapply(recs,function(r){c<-r$canonical%||%list();norm_title(c$title%||%r$title)},character(1))
stopifnot(!anyDuplicated(ids),all(nzchar(ids)))
id_map <- setNames(seq_along(ids),ids)
doi_groups <- split(which(nzchar(dois)),dois[nzchar(dois)])
title_groups <- split(which(nzchar(titles)),titles[nzchar(titles)])
audit <- list(); matched <- character()
for(i in seq_along(corr)){
  p<-corr[[i]]; nd<-scalar(p$doi_normalized); nt<-scalar(p$title_normalized); oldid<-scalar(p$record_id_at_edit)
  j<-NULL; basis<-NULL
  if(nzchar(oldid)&&oldid%in%names(id_map)){
    k<-id_map[[oldid]]
    if((!nzchar(nd)||identical(dois[[k]],nd)) || (!nzchar(nt)||identical(titles[[k]],nt))){j<-k;basis<-'record_id_at_edit'}
  }
  if(is.null(j)&&nzchar(nd)){
    hs<-doi_groups[[nd]]
    if(length(hs)==1L){j<-hs[[1L]];basis<-'doi'}
    else if(length(hs)>1L&&nzchar(nt)){th<-hs[titles[hs]==nt];if(length(th)==1L){j<-th[[1L]];basis<-'doi+title'}}
  }
  if(is.null(j)&&nzchar(nt)){hs<-title_groups[[nt]];if(length(hs)==1L){j<-hs[[1L]];basis<-'title'}}
  if(is.null(j)||length(j)!=1L)stop(sprintf('Correction %d does not resolve uniquely',i),call.=FALSE)
  id<-ids[[j]]; new_abs<-scalar(p$edited_abstract); stopifnot(nzchar(new_abs))
  r<-recs[[j]]; can<-r$canonical%||%list()
  can$abstract<-new_abs
  prov<-can$field_provenance%||%list()
  prov$abstract_human_w04<-list(source='workflow04_human_abstract_correction',source_w04_resume_run_id=as.character(p$source_w04_resume_run_id),identity_basis=basis)
  can$field_provenance<-prov; r$canonical<-can; recs[[j]]<-r
  matched<-c(matched,id)
  audit[[length(audit)+1L]]<-list(current_record_id=id,record_id_at_edit=oldid,identity_basis=basis)
}
stopifnot(length(matched)==157L,!anyDuplicated(matched))
out<-file('inputs/current/canonical_lean.jsonl','wt',encoding='UTF-8')
for(r in recs)writeLines(toJSON(r,auto_unbox=TRUE,null='null',na='null',digits=NA),out,useBytes=TRUE)
close(out)
dir.create('outputs/human_overlay',recursive=TRUE,showWarnings=FALSE)
con<-file('outputs/human_overlay/audit.jsonl','wt',encoding='UTF-8')
for(a in audit)writeLines(toJSON(a,auto_unbox=TRUE),con,useBytes=TRUE)
close(con)
cat('PASS: overlaid all 157 protected human abstracts\n')

