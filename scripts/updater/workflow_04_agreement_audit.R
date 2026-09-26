#!/usr/bin/env Rscript
suppressPackageStartupMessages(library(jsonlite))

args<-commandArgs(trailingOnly=TRUE)
arg<-function(flag,default=NULL){i<-match(flag,args);if(is.na(i))return(default);if(i==length(args))stop(sprintf("Missing value after %s",flag),call.=FALSE);args[[i+1L]]}
pass_root<-arg("--pass-root")
historical_path<-arg("--historical")
consensus_path<-arg("--consensus")
output_path<-arg("--output","workflow04_agreement_summary.json")
if(any(vapply(list(pass_root,historical_path,consensus_path),is.null,logical(1))))stop("Required: --pass-root --historical --consensus",call.=FALSE)

read_jsonl<-function(path){x<-readLines(path,warn=FALSE,encoding="UTF-8");x<-x[nzchar(trimws(x))];lapply(x,function(z)fromJSON(z,simplifyVector=FALSE))}
scalar<-function(x){if(is.null(x)||!length(x))return("");z<-as.character(x[[1L]]);if(is.na(z))"" else trimws(z)}

files1<-list.files(pass_root,pattern="^pass1\\.jsonl$",recursive=TRUE,full.names=TRUE)
files2<-list.files(pass_root,pattern="^pass2\\.jsonl$",recursive=TRUE,full.names=TRUE)
files3<-list.files(pass_root,pattern="^pass3_conflicts\\.jsonl$",recursive=TRUE,full.names=TRUE)
if(!length(files1)||!length(files2))stop("No pass files found",call.=FALSE)

bind_pass<-function(files,name){
  rows<-unlist(lapply(files,read_jsonl),recursive=FALSE)
  data.frame(record_id=vapply(rows,function(x)scalar(x$record_id),character(1)),
             decision=vapply(rows,function(x)scalar(x$decision),character(1)),
             stringsAsFactors=FALSE)
}
p1<-bind_pass(files1,"p1");names(p1)[2]<-"p1"
p2<-bind_pass(files2,"p2");names(p2)[2]<-"p2"
p3<-if(length(files3)){z<-bind_pass(files3,"p3");names(z)[2]<-"p3";z}else data.frame(record_id=character(),p3=character())

historical<-read_jsonl(historical_path)
hist<-data.frame(record_id=vapply(historical,function(x)scalar(x$record_id),character(1)),
                 historical=vapply(historical,function(x)scalar(x$screening$decision),character(1)),
                 stringsAsFactors=FALSE)
consensus<-read_jsonl(consensus_path)
con<-data.frame(record_id=vapply(consensus,function(x)scalar(x$record_id),character(1)),
                consensus=vapply(consensus,function(x)scalar(x$screening$decision),character(1)),
                stringsAsFactors=FALSE)

for(x in list(p1,p2,p3,hist,con))if(anyDuplicated(x$record_id))stop("Duplicate record_id invariant failed",call.=FALSE)
d<-merge(p1,p2,by="record_id",all=TRUE)
d<-merge(d,con,by="record_id",all=TRUE)
d<-merge(d,hist,by="record_id",all.x=TRUE)
d<-merge(d,p3,by="record_id",all.x=TRUE)
if(nrow(d)!=32283L)stop(sprintf("Expected 32,283 records, found %d",nrow(d)),call.=FALSE)

kappa2<-function(a,b,cats){
  n<-length(a);po<-mean(a==b)
  pa<-table(factor(a,levels=cats))/n
  pb<-table(factor(b,levels=cats))/n
  pe<-sum(pa*pb)
  k<-(po-pe)/(1-pe)
  list(n=n,agreement=unname(po),cohen_kappa=unname(k))
}
fleiss_binary<-function(mat){
  cats<-c("retain","exclude");n<-nrow(mat);m<-ncol(mat)
  counts<-t(apply(mat,1,function(r)c(sum(r=="retain"),sum(r=="exclude"))))
  Pi<-(rowSums(counts^2)-m)/(m*(m-1))
  Pbar<-mean(Pi);pj<-colSums(counts)/(n*m);Pe<-sum(pj^2)
  list(n=n,fleiss_kappa=unname((Pbar-Pe)/(1-Pe)),
       unanimous_agreement=mean(apply(mat,1,function(r)length(unique(r))==1)),
       unanimous_count=sum(apply(mat,1,function(r)length(unique(r))==1)))
}

histd<-d[!is.na(d$historical),]
p12_sub<-d[d$p1!="uncertain"&d$p2!="uncertain",]
p1h_sub<-histd[histd$p1!="uncertain",]
p2h_sub<-histd[histd$p2!="uncertain",]
ch_sub<-histd[histd$consensus!="uncertain",]
p3h<-histd[!is.na(histd$p3),]
p3h_sub<-p3h[p3h$p3!="uncertain",]
tri<-histd[histd$p1!="uncertain"&histd$p2!="uncertain",]

res<-list(
  schema="living-evidence-map-workflow04-agreement-summary-v1",
  historical_comparator_records=nrow(histd),
  pass1_vs_pass2=list(
    all_records=kappa2(d$p1,d$p2,c("retain","exclude","uncertain")),
    both_substantive=kappa2(p12_sub$p1,p12_sub$p2,c("retain","exclude")),
    at_least_one_uncertain=sum(d$p1=="uncertain"|d$p2=="uncertain"),
    opposing_substantive_decisions=sum(d$p1!="uncertain"&d$p2!="uncertain"&d$p1!=d$p2),
    third_pass_queue=nrow(p3)
  ),
  pass1_vs_historical=list(
    all_three_category=kappa2(histd$p1,histd$historical,c("retain","exclude","uncertain")),
    substantive_binary=kappa2(p1h_sub$p1,p1h_sub$historical,c("retain","exclude")),
    luna_uncertain=sum(histd$p1=="uncertain")
  ),
  pass2_vs_historical=list(
    all_three_category=kappa2(histd$p2,histd$historical,c("retain","exclude","uncertain")),
    substantive_binary=kappa2(p2h_sub$p2,p2h_sub$historical,c("retain","exclude")),
    luna_uncertain=sum(histd$p2=="uncertain")
  ),
  consensus_vs_historical=list(
    all_three_category=kappa2(histd$consensus,histd$historical,c("retain","exclude","uncertain")),
    substantive_binary=kappa2(ch_sub$consensus,ch_sub$historical,c("retain","exclude")),
    agreement_count=sum(ch_sub$consensus==ch_sub$historical),
    disagreement_count=sum(ch_sub$consensus!=ch_sub$historical),
    historical_retain_luna_exclude=sum(ch_sub$historical=="retain"&ch_sub$consensus=="exclude"),
    historical_exclude_luna_retain=sum(ch_sub$historical=="exclude"&ch_sub$consensus=="retain"),
    luna_unresolved=sum(histd$consensus=="uncertain")
  ),
  three_rater_historical_pass1_pass2=fleiss_binary(as.matrix(tri[,c("historical","p1","p2")])),
  pass3_vs_historical_selected_subset=list(
    all_three_category=kappa2(p3h$p3,p3h$historical,c("retain","exclude","uncertain")),
    substantive_binary=kappa2(p3h_sub$p3,p3h_sub$historical,c("retain","exclude")),
    pass3_uncertain=sum(p3h$p3=="uncertain"),
    selection_note="Pass 3 is a selectively enriched difficult subset and is not directly comparable with full-pass metrics."
  ),
  methodological_note="Agreement is calculated from original Luna outputs before historical overrides or fallbacks. Historical decisions are a previous-screening comparator, not an independent gold standard."
)
writeLines(toJSON(res,auto_unbox=TRUE,pretty=TRUE,digits=NA),output_path,useBytes=TRUE)
cat(toJSON(res,auto_unbox=TRUE,pretty=TRUE,digits=NA),"\n")
