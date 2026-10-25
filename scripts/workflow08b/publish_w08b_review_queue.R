#!/usr/bin/env Rscript
# Automatic W08b ambiguous-cluster adjudication publisher, with stable queue identity.
# Input: identity_crosswalk.csv, two full bibliography JSONL, historical W01 canonical JSONL.
suppressPackageStartupMessages({library(jsonlite);library(data.table);library(googlesheets4);library(digest)})
`%||%`<-function(x,y)if(is.null(x))y else x

a<-commandArgs(trailingOnly=TRUE)
if(length(a)!=5L)stop("Usage: publish_w08b_review_queue.R identity_crosswalk.csv lens.jsonl openalex.jsonl historical_w01.jsonl output_dir")
for(p in a[1:4])if(!file.exists(p))stop("Missing input: ",p)
out<-a[[5]];dir.create(out,recursive=TRUE,showWarnings=FALSE)
sheet_id<-Sys.getenv("LEM_GOOGLE_SHEET_ID","")
credential<-Sys.getenv("LEM_GOOGLE_SERVICE_ACCOUNT_JSON","")
if(!nzchar(sheet_id)||!nzchar(credential))stop("Shiny Google Sheets credentials missing")
if(!file.exists(credential)){
 f<-file.path(out,"service_account.json");writeLines(credential,f);Sys.chmod(f,"0600")
 credential<-f
}
gs4_auth(path=credential,cache=FALSE)
d<-fread(a[[1]],colClasses="character",na.strings=NULL)
need<-c("candidate_key","provider","provider_id","cluster","status","matched_w01_ids")
if(!all(need%in%names(d)))stop("Dedup identity crosswalk schema mismatch")
groups<-unique(d[status=="ambiguous_historical",cluster])
if(!length(groups)){
 writeLines(toJSON(list(schema="w08b-human-review-queue-v1",case_count=0L,status="no_review_required"),
  auto_unbox=TRUE,pretty=TRUE),file.path(out,"review_queue_manifest.json"))
 cat("PASS: no ambiguous historical clusters require Shiny adjudication\n")
 quit(status=0L)
}
requested<-unique(d[cluster%in%groups,candidate_key])
candidates<-new.env(hash=TRUE,parent=emptyenv())
take<-function(path,source){
 con<-file(path,"rt");on.exit(close(con))
 repeat{
  lines<-readLines(con,n=250L,warn=FALSE);if(!length(lines))break
  for(line in lines){
   if(!nzchar(line))next
   z<-fromJSON(line,simplifyVector=FALSE)
   id<-if(source=="lens")as.character(z$identity$lens_id%||%"") else as.character(z$sidecar_identity$openalex_id%||%"")
   key<-paste0(source,":",id)
   if(key%in%requested){
    c<-if(source=="lens")z$canonical else z$mapped_fields
    assign(key,list(provider=source,source_id=id,title=c$title%||%"",doi=c$doi%||%"",
      abstract=c$abstract%||%"",year=c$year%||%"",authors=c$authors%||%list()),envir=candidates)
   }
  }
 }
}
take(a[[2]],"lens");take(a[[3]],"openalex")
if(any(!vapply(requested,exists,logical(1),envir=candidates,inherits=FALSE)))stop("Missing ambiguous candidate metadata")
history_ids<-unique(unlist(strsplit(d[cluster%in%groups & nzchar(matched_w01_ids),matched_w01_ids],"|",fixed=TRUE),use.names=FALSE))
historical<-new.env(hash=TRUE,parent=emptyenv())
con<-file(a[[4]],"rt")
repeat{
 lines<-readLines(con,n=250L,warn=FALSE);if(!length(lines))break
 for(line in lines){
  if(!nzchar(line))next
  z<-fromJSON(line,simplifyVector=FALSE)
  id<-as.character(z$identity$record_id%||%"")
  if(id%in%history_ids){
   c<-z$canonical%||%list()
   assign(id,list(w01_record_id=id,title=c$title%||%"",doi=c$doi%||%"",
    abstract=c$abstract%||%"",year=c$year%||%"",authors=c$authors%||%list()),envir=historical)
  }
 }
}
close(con)
if(any(!vapply(history_ids,exists,logical(1),envir=historical,inherits=FALSE)))stop("Historical W01 record missing")
rows<-lapply(seq_along(groups),function(i){
 target_cluster<-groups[[i]];g<-d[cluster==target_cluster]
 keys<-unique(g$candidate_key)
 ids<-unique(unlist(strsplit(g$matched_w01_ids[nzchar(g$matched_w01_ids)],"|",fixed=TRUE),use.names=FALSE))
 case<-list(review_case_id=paste0("w08b-ambiguous-",target_cluster),
   cluster_id=target_cluster,
   candidates=lapply(keys,function(k)get(k,envir=candidates,inherits=FALSE)),
   historical=lapply(ids,function(k)get(k,envir=historical,inherits=FALSE)),
   match_methods=unique(unlist(strsplit(g$match_methods[nzchar(g$match_methods)],"|",fixed=TRUE),use.names=FALSE)))
 as.character(toJSON(case,auto_unbox=TRUE,null="null",na="null"))
})
ids<-paste0("w08b-ambiguous-",groups)
sha<-digest(paste0(paste(rows,collapse="\n"),"\n"),algo="sha256",serialize=FALSE)
batch<-paste0("w08b-citation-dedup-",substr(sha,1L,12L))
queue<-data.frame(batch_id=batch,queue_sha256=sha,case_index=as.character(seq_along(rows)),
 review_case_id=ids,case_json=unlist(rows,use.names=FALSE),stringsAsFactors=FALSE)
write.csv(queue,file.path(out,"w08b_review_queue.csv"),row.names=FALSE,na="")
tabs<-sheet_names(sheet_id)
qtab<-"queue_w08b_dedup_active";dtab<-"decisions_w08b_dedup"
if(qtab%in%tabs){
 prior<-read_sheet(sheet_id,sheet=qtab,col_types="c")
 if(nrow(prior)){
  if(!"queue_sha256"%in%names(prior) || !all(prior$queue_sha256==sha))
   stop("A different W08b review queue exists; refusing destructive replacement")
  message("PASS: same W08b review queue already installed")
 }else sheet_write(queue,ss=sheet_id,sheet=qtab)
}else sheet_write(queue,ss=sheet_id,sheet=qtab)
if(!dtab%in%sheet_names(sheet_id)){
 blank<-data.frame(decision_id=character(),review_case_id=character(),decision=character(),
  target_w01_id=character(),rationale=character(),reviewer=character(),
  decided_at_utc=character(),queue_sha256=character())
 sheet_write(blank,ss=sheet_id,sheet=dtab)
}
writeLines(toJSON(list(schema="w08b-human-review-queue-v1",batch_id=batch,queue_sha256=sha,
 case_count=length(groups),shiny_queue_tab=qtab,shiny_decision_tab=dtab,
 historical_candidates=length(history_ids),status="published_to_shiny"),
 auto_unbox=TRUE,pretty=TRUE),file.path(out,"review_queue_manifest.json"))
cat("PASS: published ",length(groups)," ambiguous W08b clusters to Shiny tab ",qtab,"\n",sep="")
