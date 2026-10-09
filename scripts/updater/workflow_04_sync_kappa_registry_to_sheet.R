#!/usr/bin/env Rscript
suppressPackageStartupMessages({library(googlesheets4);library(digest)})

args<-commandArgs(trailingOnly=TRUE)
arg<-function(flag,default=NULL){i<-match(flag,args);if(is.na(i))return(default);if(i==length(args))stop(sprintf("Missing value after %s",flag),call.=FALSE);args[[i+1L]]}
registry_path<-arg("--registry")
sheet_id<-arg("--sheet-id")
credential<-arg("--credential")
tab<-arg("--tab","w04_kappa_registry")
if(any(vapply(list(registry_path,sheet_id,credential),is.null,logical(1))))stop("Required: --registry --sheet-id --credential",call.=FALSE)
if(!file.exists(registry_path)||!file.exists(credential))stop("Registry/credential input missing",call.=FALSE)

cols<-c(
  "registry_row_id","date","source","batch_id","queue_sha256","workflow04_run_id",
  "records_reviewed","records_compared",
  "model_retain_human_retain","model_retain_human_exclude",
  "model_exclude_human_retain","model_exclude_human_exclude",
  "human_uncertain","model_uncertain","raw_agreement","human_model_kappa",
  "humans_model_fleiss_kappa","created_at_utc","source_github_run_id"
)
normalise<-function(x){
  miss<-setdiff(cols,names(x));if(length(miss))stop("Kappa registry missing columns: ",paste(miss,collapse=", "),call.=FALSE)
  x<-x[,cols,drop=FALSE]
  for(n in cols){x[[n]]<-as.character(x[[n]]);x[[n]][is.na(x[[n]])]<-""}
  if(any(!nzchar(x$registry_row_id))||anyDuplicated(x$registry_row_id))stop("Kappa registry row identity invariant failed",call.=FALSE)
  x
}
row_signature<-function(x){
  x<-normalise(x)
  setNames(vapply(seq_len(nrow(x)),function(i)digest(paste(unlist(x[i,,drop=FALSE],use.names=FALSE),collapse="\t"),algo="sha256",serialize=FALSE),character(1)),x$registry_row_id)
}

gh<-normalise(read.csv(registry_path,stringsAsFactors=FALSE,check.names=FALSE,colClasses="character",na.strings=NULL))
gs4_auth(path=credential,cache=FALSE)
tabs<-sheet_names(sheet_id)
if(!tab%in%tabs){
  sheet_add(sheet_id,sheet=tab)
  sheet_write(gh,ss=sheet_id,sheet=tab)
  cat(sprintf("PASS: created Google kappa registry mirror with %d row(s)\n",nrow(gh)))
  quit(save="no",status=0)
}
g<-read_sheet(sheet_id,sheet=tab,col_types="c")
if(!nrow(g)){
  sheet_write(gh,ss=sheet_id,sheet=tab)
  cat(sprintf("PASS: restored empty Google kappa registry mirror from GitHub (%d row(s))\n",nrow(gh)))
  quit(save="no",status=0)
}
g<-normalise(g)
gs<-row_signature(g);hs<-row_signature(gh)
extra<-setdiff(names(gs),names(hs))
if(length(extra))stop("Google kappa registry contains row(s) absent from GitHub: ",paste(extra,collapse=", "),call.=FALSE)
shared<-intersect(names(gs),names(hs))
bad<-shared[gs[shared]!=hs[shared]]
if(length(bad))stop("Google/GitHub kappa registry disagreement for row(s): ",paste(bad,collapse=", "),call.=FALSE)
if(length(setdiff(names(hs),names(gs)))){
  sheet_write(gh,ss=sheet_id,sheet=tab)
  cat(sprintf("PASS: advanced Google kappa registry mirror to %d authoritative GitHub row(s)\n",nrow(gh)))
}else{
  cat(sprintf("PASS: Google and GitHub kappa registries are identical (%d row(s))\n",nrow(gh)))
}
