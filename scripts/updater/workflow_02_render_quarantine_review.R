#!/usr/bin/env Rscript
suppressPackageStartupMessages({
  library(jsonlite)
  library(data.table)
  library(stringdist)
  library(stringi)
})

args<-commandArgs(trailingOnly=TRUE)
arg<-function(flag,default=NULL){i<-match(flag,args);if(is.na(i))return(default);if(i==length(args))stop(sprintf("Missing value after %s",flag),call.=FALSE);args[[i+1L]]}
canonical<-arg("--canonical")
audit<-arg("--audit")
out_csv<-arg("--out-csv")
out_jsonl<-arg("--out-jsonl")
summary_path<-arg("--summary")
if(any(vapply(list(canonical,audit,out_csv,out_jsonl,summary_path),is.null,logical(1))))stop("Required: --canonical --audit --out-csv --out-jsonl --summary",call.=FALSE)

`%||%`<-function(x,y)if(is.null(x))y else x
clean_text<-function(x){
  if(is.null(x)||!length(x))return(NA_character_)
  s<-as.character(x[[1L]])
  s<-gsub("&lt;/?i&gt;|&lt;/?b&gt;|<[^>]+>"," ",s,ignore.case=TRUE)
  s<-gsub("&amp;","&",s,fixed=TRUE)
  s<-gsub("&quot;",""",s,fixed=TRUE)
  s<-stri_trans_general(s,"Latin-ASCII")
  s<-tolower(s)
  s<-gsub("[^a-z0-9]+"," ",s)
  trimws(gsub("\\s+"," ",s))
}
tokens<-function(s){
  if(is.na(s)||!nzchar(s))return(character())
  unique(strsplit(s," ",fixed=TRUE)[[1L]])
}
overlap_metrics<-function(a,b){
  ta<-tokens(a);tb<-tokens(b)
  if(!length(ta)||!length(tb))return(c(jaccard=NA_real_,containment=NA_real_))
  inter<-length(intersect(ta,tb))
  c(jaccard=inter/length(union(ta,tb)),containment=inter/min(length(ta),length(tb)))
}
jw<-function(a,b){
  if(is.na(a)||is.na(b)||!nzchar(a)||!nzchar(b))return(NA_real_)
  1-stringdist(a,b,method="jw",p=0.1)
}
readjl<-function(p){
  x<-readLines(p,warn=FALSE,encoding="UTF-8");x<-x[nzchar(trimws(x))]
  lapply(x,fromJSON,simplifyVector=FALSE)
}

# Index canonical titles by stable work ID.
idx<-new.env(hash=TRUE,parent=emptyenv())
con<-file(canonical,"rt",encoding="UTF-8")
repeat{
  ln<-readLines(con,n=1L,warn=FALSE);if(!length(ln))break;if(!nzchar(trimws(ln)))next
  r<-fromJSON(ln,simplifyVector=FALSE)
  id<-as.character((r$identity%||%list())$record_id%||%"")
  if(nzchar(id))assign(id,list(title=(r$canonical%||%list())$title,doi=(r$canonical%||%list())$doi),envir=idx)
}
close(con)

aud<-readjl(audit)
rows<-list()
for(r in aud){
  qs<-r$quarantined%||%list()
  if(!length(qs))next
  for(q in qs){
    if(!identical(q$reason,"title_mismatch"))next
    id<-as.character(r$record_id%||%"")
    can<-if(exists(id,envir=idx,inherits=FALSE))get(id,envir=idx) else list(title=NULL,doi=NULL)
    provider<-as.character(q$provider%||%"")
    pr<-if(provider=="scopus")r$scopus else r$europe_pmc
    ct<-as.character(can$title%||%"")
    pt<-as.character(pr$title%||%"")
    ca<-clean_text(ct);pa<-clean_text(pt)
    om<-overlap_metrics(ca,pa)
    jw2<-jw(ca,pa)
    containment_text<-nzchar(ca)&&nzchar(pa)&&(grepl(ca,pa,fixed=TRUE)||grepl(pa,ca,fixed=TRUE))
    proposed<-if(containment_text || (!is.na(om[["containment"]])&&om[["containment"]]>=0.95)){
      "auto_accept_same_title"
    }else if((!is.na(jw2)&&jw2>=0.90)||(!is.na(om[["containment"]])&&om[["containment"]]>=0.85)){
      "high_overlap_review"
    }else{
      "manual_review"
    }
    rows[[length(rows)+1L]]<-list(
      record_id=id,
      doi=as.character(r$doi%||%""),
      provider=provider,
      original_title_similarity=as.numeric(q$title_similarity%||%NA_real_),
      canonical_title=ct,
      provider_title=pt,
      normalised_title_similarity=jw2,
      token_jaccard=unname(om[["jaccard"]]),
      token_containment=unname(om[["containment"]]),
      title_containment=containment_text,
      proposed_class=proposed,
      provider_abstract=as.character(pr$abstract%||%"")
    )
  }
}
if(length(rows)!=199L)stop(sprintf("Expected 199 quarantined title mismatches; found %d",length(rows)),call.=FALSE)

dt<-rbindlist(rows,fill=TRUE)
dir.create(dirname(out_csv),recursive=TRUE,showWarnings=FALSE)
fwrite(dt,out_csv)
con<-file(out_jsonl,"wt",encoding="UTF-8")
for(x in rows)writeLines(toJSON(x,auto_unbox=TRUE,null="null",na="null"),con,useBytes=TRUE)
close(con)
counts<-as.list(table(dt$proposed_class))
summary<-list(schema="workflow02-quarantine-review-v1",total=nrow(dt),by_provider=as.list(table(dt$provider)),proposed_classes=counts)
writeLines(toJSON(summary,auto_unbox=TRUE,pretty=TRUE,null="null"),summary_path,useBytes=TRUE)
cat(sprintf("PASS: rendered %d quarantined title mismatches: %s\n",nrow(dt),paste(names(counts),unlist(counts),sep="=",collapse=", ")))
