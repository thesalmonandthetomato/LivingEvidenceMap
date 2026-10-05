#!/usr/bin/env Rscript
suppressPackageStartupMessages({library(jsonlite);library(digest)})

args<-commandArgs(trailingOnly=TRUE)
arg<-function(flag,default=NULL){i<-match(flag,args);if(is.na(i))return(default);if(i==length(args))stop(sprintf("Missing value after %s",flag),call.=FALSE);args[[i+1L]]}
`%||%`<-function(x,y)if(is.null(x))y else x

registry_path<-arg("--registry")
human_path<-arg("--human-decisions")
model_path<-arg("--model-reference")
batch_id<-arg("--batch-id")
queue_sha<-tolower(arg("--queue-sha256",""))
workflow04_run_id<-arg("--workflow04-run-id","")
source_run_id<-arg("--source-github-run-id","")
output_path<-arg("--output",registry_path)

required<-list(registry_path,human_path,model_path,batch_id,output_path)
if(any(vapply(required,is.null,logical(1))))stop("Required: --registry --human-decisions --model-reference --batch-id --output",call.=FALSE)
for(p in c(registry_path,human_path,model_path))if(!file.exists(p))stop("Missing input: ",p,call.=FALSE)
if(!grepl("^[0-9a-f]{64}$",queue_sha))stop("--queue-sha256 must be SHA-256",call.=FALSE)

cols<-c(
  "registry_row_id","date","source","batch_id","queue_sha256","workflow04_run_id",
  "records_reviewed","records_compared",
  "model_retain_human_retain","model_retain_human_exclude",
  "model_exclude_human_retain","model_exclude_human_exclude",
  "human_uncertain","model_uncertain","raw_agreement","human_model_kappa",
  "humans_model_fleiss_kappa","created_at_utc","source_github_run_id"
)

norm<-function(x){
  x<-tolower(trimws(as.character(x)))
  ifelse(x%in%c("retain","include","included"),"retain",
         ifelse(x%in%c("exclude","excluded"),"exclude",
                ifelse(x%in%c("uncertain","unsure"),"uncertain","")))
}
read_jsonl<-function(path){
  x<-readLines(path,warn=FALSE,encoding="UTF-8");x<-x[nzchar(trimws(x))]
  lapply(x,function(z)fromJSON(z,simplifyVector=FALSE))
}
kappa_counts<-function(rr,re,er,ee){
  n<-rr+re+er+ee
  if(n<1L)return(list(n=0L,agreement=NA_real_,kappa=NA_real_))
  po<-(rr+ee)/n
  model_ret<-(rr+re)/n
  human_ret<-(rr+er)/n
  pe<-model_ret*human_ret+(1-model_ret)*(1-human_ret)
  k<-if(isTRUE(all.equal(pe,1)))NA_real_ else (po-pe)/(1-pe)
  list(n=as.integer(n),agreement=as.numeric(po),kappa=as.numeric(k))
}

registry<-read.csv(registry_path,stringsAsFactors=FALSE,check.names=FALSE,colClasses="character",na.strings=NULL)
miss<-setdiff(cols,names(registry));if(length(miss))stop("Registry missing columns: ",paste(miss,collapse=", "),call.=FALSE)
registry<-registry[,cols,drop=FALSE]
for(nm in cols){registry[[nm]][is.na(registry[[nm]])]<-""}
if(any(!nzchar(registry$registry_row_id))||anyDuplicated(registry$registry_row_id))stop("Registry row identity invariant failed",call.=FALSE)

human<-read_jsonl(human_path)
h<-data.frame(
  review_case_id=vapply(human,function(x)as.character(x$review_case_id%||%""),character(1)),
  record_id=vapply(human,function(x)as.character(x$record_id%||%""),character(1)),
  human_decision=vapply(human,function(x)norm(x$decision%||%""),character(1)),
  stringsAsFactors=FALSE
)
if(any(!nzchar(h$review_case_id))||anyDuplicated(h$review_case_id))stop("Human decision identity invariant failed",call.=FALSE)
if(any(!nzchar(h$human_decision)))stop("Human decisions contain unsupported values",call.=FALSE)

m<-read.csv(model_path,stringsAsFactors=FALSE,check.names=FALSE,colClasses="character",na.strings=NULL)
need<-c("review_case_id","record_id","model_decision")
if(!all(need%in%names(m)))stop("Model reference missing required columns",call.=FALSE)
m<-m[,need,drop=FALSE]
m$model_decision<-norm(m$model_decision)
if(any(!nzchar(m$review_case_id))||anyDuplicated(m$review_case_id))stop("Model reference identity invariant failed",call.=FALSE)
if(any(!nzchar(m$model_decision)))stop("Model reference contains unsupported values",call.=FALSE)

x<-merge(h,m,by="review_case_id",all=TRUE,suffixes=c("_human","_model"))
if(nrow(x)!=nrow(h)||any(is.na(x$record_id_human))||any(is.na(x$record_id_model)))stop("Human/model validation coverage mismatch",call.=FALSE)
if(any(x$record_id_human!=x$record_id_model))stop("Human/model record_id mismatch",call.=FALSE)

binary<-x$human_decision%in%c("retain","exclude") & x$model_decision%in%c("retain","exclude")
rr<-sum(binary & x$model_decision=="retain" & x$human_decision=="retain")
re<-sum(binary & x$model_decision=="retain" & x$human_decision=="exclude")
er<-sum(binary & x$model_decision=="exclude" & x$human_decision=="retain")
ee<-sum(binary & x$model_decision=="exclude" & x$human_decision=="exclude")
stat<-kappa_counts(rr,re,er,ee)
human_uncertain<-sum(x$human_decision=="uncertain")
model_uncertain<-sum(x$model_decision=="uncertain")
created<-format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ")
date<-format(Sys.Date(),"%Y-%m-%d")
row_id<-paste0("w04-kappa-",substr(digest(paste(batch_id,queue_sha,digest(file=human_path,algo="sha256",serialize=FALSE),digest(file=model_path,algo="sha256",serialize=FALSE),sep="|"),algo="sha256",serialize=FALSE),1L,24L))

row<-data.frame(
  registry_row_id=row_id,date=date,source="shiny_validation",batch_id=as.character(batch_id),
  queue_sha256=queue_sha,workflow04_run_id=as.character(workflow04_run_id),
  records_reviewed=as.character(nrow(x)),records_compared=as.character(stat$n),
  model_retain_human_retain=as.character(rr),model_retain_human_exclude=as.character(re),
  model_exclude_human_retain=as.character(er),model_exclude_human_exclude=as.character(ee),
  human_uncertain=as.character(human_uncertain),model_uncertain=as.character(model_uncertain),
  raw_agreement=if(is.na(stat$agreement))"" else format(stat$agreement,digits=17,scientific=FALSE,trim=TRUE),
  human_model_kappa=if(is.na(stat$kappa))"" else format(stat$kappa,digits=17,scientific=FALSE,trim=TRUE),
  humans_model_fleiss_kappa="",
  created_at_utc=created,source_github_run_id=as.character(source_run_id),
  stringsAsFactors=FALSE
)

same_batch<-registry$batch_id==batch_id
if(any(same_batch)){
  hit<-registry[same_batch,,drop=FALSE]
  if(nrow(hit)==1L && identical(as.character(hit$registry_row_id),row_id)){
    cat(sprintf("PASS: W04 kappa registry already contains idempotent batch %s\n",batch_id))
    dir.create(dirname(output_path),recursive=TRUE,showWarnings=FALSE)
    write.csv(registry,output_path,row.names=FALSE,na="")
    quit(save="no",status=0)
  }
  stop("Registry already contains this batch_id with different provenance",call.=FALSE)
}

out<-rbind(registry,row)
if(anyDuplicated(out$registry_row_id)||anyDuplicated(out$batch_id))stop("Registry uniqueness invariant failed",call.=FALSE)
dir.create(dirname(output_path),recursive=TRUE,showWarnings=FALSE)
write.csv(out,output_path,row.names=FALSE,na="")
cat(sprintf("PASS: appended W04 kappa batch %s: reviewed=%d compared=%d kappa=%s\n",batch_id,nrow(x),stat$n,if(is.na(stat$kappa))"NA" else sprintf("%.6f",stat$kappa)))
