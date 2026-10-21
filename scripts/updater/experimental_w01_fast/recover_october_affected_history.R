#!/usr/bin/env Rscript
# Read-only ZIP64 STORED member extraction with hard transfer/size caps.
# Never downloads or unpacks the complete 27 GB GitHub Actions archive.
artifact_id <- "12259032049"
repo <- "thesalmonandthetomato/LivingEvidenceMap"
selected <- c("previous_state/canonical/records.jsonl")
out <- "october_historical_affected_source"
if (file.exists(out) || dir.exists(out)) stop("Refuse to overwrite extraction")
token <- Sys.getenv("GH_TOKEN")
if (!nzchar(token)) stop("Missing read-only Actions token")
dir.create(out)
dir.create(file.path(out,"metadata"))
curl <- function(args, result=NULL) {
 code <- suppressWarnings(system(paste("curl",paste(args,collapse=" "),"1>/dev/null"),intern=FALSE,ignore.stderr=FALSE))
 if (!identical(as.integer(code),0L)) stop("Bounded remote request failed: curl exit ",code)
}
endpoint <- paste0("https://api.github.com/repos/",repo,"/actions/artifacts/",artifact_id,"/zip")
redirect <- tempfile()
curl(c("--silent","--show-error","--head","--fail","--max-time","30",
 "-H",shQuote(paste("Authorization: Bearer",token)),
 "-H",shQuote("Accept: application/vnd.github+json"),
 "--dump-header",shQuote(redirect),"--output","/dev/null",shQuote(endpoint)))
h<-readLines(redirect,warn=FALSE);unlink(redirect)
loc<-grep("^location: ",h,value=TRUE,ignore.case=TRUE)
if(length(loc)!=1L)stop("Expected one signed storage URL")
signed<-trimws(sub("^[^:]+: ","",loc))
if(!startsWith(signed,"https://productionresult")||
 !grepl(".blob.core.windows.net/",signed,fixed=TRUE))stop("Unexpected storage host")
request<-function(start,end,path,cap){
 if(start<0||end<start||(end-start+1)>cap)stop("Unsafe byte range")
 curl(c("--silent","--show-error","--fail","--max-time","120",
 "-H",shQuote(sprintf("x-ms-range: bytes=%.0f-%.0f",start,end)),
 "--output",shQuote(path),shQuote(signed)))
 if (!file.exists(path)||file.info(path)$size != (end-start+1))
  stop("Storage did not honour exact range")
}
total<-27460488363
tail_path<-tempfile();request(total-65536,total-1,tail_path,65536)
b<-readBin(tail_path,"raw",n=65536);unlink(tail_path)
num<-function(x,p,n){
 if(p<0||p+n>length(x))stop("Truncated ZIP directory")
 sum(as.numeric(x[(p+1):(p+n)])*256^(seq_len(n)-1))
}
sig<-function(x,p,bytes) p>=0&&p+length(bytes)<=length(x)&&
 identical(x[(p+1):(p+length(bytes))],as.raw(bytes))
found<-which(b==as.raw(0x50))
found<-found[vapply(found,function(p)sig(b,p-1,c(0x50,0x4b,0x01,0x02)),logical(1))]
if(!length(found))stop("No ZIP central directory")
entries<-list();p<-min(found)-1
while(sig(b,p,c(0x50,0x4b,0x01,0x02))){
 namelen<-num(b,p+28,2);extralen<-num(b,p+30,2);commentlen<-num(b,p+32,2)
 name<-rawToChar(b[(p+47):(p+46+namelen)])
 compressed<-num(b,p+20,4);uncompressed<-num(b,p+24,4)
 offset<-num(b,p+42,4);method<-num(b,p+10,2)
 q<-p+46+namelen;stopat<-q+extralen
 while(q<stopat){
  type<-num(b,q,2);len<-num(b,q+2,2)
  if(type==1){
   v<-q+4
   if(uncompressed==4294967295){uncompressed<-num(b,v,8);v<-v+8}
   if(compressed==4294967295){compressed<-num(b,v,8);v<-v+8}
   if(offset==4294967295)offset<-num(b,v,8)
  }
  q<-q+4+len
 }
 entries[[name]]<-list(offset=offset,size=compressed,uncompressed=uncompressed,method=method)
 p<-p+46+namelen+extralen+commentlen
}


if(!"previous_state/canonical/records.jsonl"%in%names(entries))stop("Missing original canonical reference")
e<-entries[["previous_state/canonical/records.jsonl"]]
if(e$method!=0||e$size!=e$uncompressed||e$size>700000000)stop("Invalid historic canonical ZIP member")
header<-tempfile();request(e$offset,e$offset+255,header,256)
x<-readBin(header,"raw",n=256);unlink(header)
if(!sig(x,0,c(0x50,0x4b,0x03,0x04)))stop("Invalid local ZIP header")
fname<-num(x,26,2);extra<-num(x,28,2)
data_offset<-e$offset+30+fname+extra
if(!identical(rawToChar(x[31:(30+fname)]),"previous_state/canonical/records.jsonl"))
 stop("Local archived member differs")
suppressPackageStartupMessages({library(data.table);library(jsonlite)})
a<-fread("october_affected_scope/affected_cluster_map.csv",colClasses=list(character=c("source","source_record_id","cluster_id")))
o<-fread("reference/previous_state/workflow01_full_five_source/manifestation_cluster_map.csv",
 colClasses=list(character=c("source","source_record_id","cluster_id")))
selected<-sort(unique(a$cluster_id))
if(length(selected)!=44L)stop("Unexpected affected historical works")
total_bytes<-0
read_mid_record<-function(position){
 for(span in c(32768,131072,262144)){
   start<-max(0,floor(position-span));end<-min(e$size-1,floor(position+span))
   bytes<-end-start+1
   total_bytes<<-total_bytes+bytes
   if(total_bytes>120000000)stop("Exceeded 120MB strict ranged-transfer budget")
   f<-tempfile();request(data_offset+start,data_offset+end,f,bytes)
   d<-readBin(f,"raw",n=bytes);unlink(f)
   newlines<-which(d==as.raw(10))
   relative<-position-start+1
   prev<-newlines[newlines<relative];nexts<-newlines[newlines>=relative]
   first<-if(start==0&&length(prev)==0L)0L else if(length(prev))tail(prev,1L)else NA_integer_
   stopat<-if(length(nexts))nexts[[1L]]else NA_integer_
   if(!is.na(first)&&!is.na(stopat)&&stopat>first+1L){
     value<-tryCatch(fromJSON(rawToChar(d[(first+1L):(stopat-1L)]),simplifyVector=FALSE),error=function(e)NULL)
     if(!is.null(value)&&is.list(value$deduplication)&&nzchar(value$deduplication$cluster_id))
       return(value)
   }
 }
 stop("Cannot locate bounded complete canonical JSONL record at target byte position")
}
find_work<-function(target){
 low<-0;high<-e$size-1;tries<-0L
 while(low<=high&&tries<43L){
  mid<-floor((low+high)/2)
  record<-read_mid_record(mid);tries<-tries+1L
  candidate<-as.character(record$deduplication$cluster_id)
  if(identical(candidate,target))return(record)
  if(candidate<target)low<-mid+1 else high<-mid-1
 }
 stop(sprintf("Cannot locate canonical work %s by ordered reference bytes",target))
}

key<-function(s,id)paste0(nchar(s,type="bytes"),":",s,nchar(id,type="bytes"),":",id)
historic<-o[cluster_id%in%selected]
wanted<-key(historic$source,historic$source_record_id)
seen<-character()
records<-vector("list",length(selected))
for(i in seq_along(selected)){
 work<-find_work(selected[[i]])
 mans<-work$manifestations
 keys<-vapply(mans,function(m)key(m$source,m$source_record_id),character(1))
 if(anyDuplicated(keys)||!setequal(keys,wanted[historic$cluster_id==selected[[i]]]))
  stop("Historical canonical member identity mismatch: ",selected[[i]])
 seen<-c(seen,keys)
 records[[i]]<-list(work_id=selected[[i]],historical_manifestations=length(keys),
  complete_canonical_record_recovered=TRUE)
 if(i%%10L==0L||i==length(selected))cat(sprintf("Recovered historic work %d/%d; transfer %.1f MiB\\n",i,length(selected),total_bytes/1048576))
}
if(length(seen)!=177L||anyDuplicated(seen)||!setequal(seen,wanted))
 stop("Missing or duplicated historical manifestation from archived canonical works")
dir.create(file.path(out,"audit"),recursive=TRUE)
write_json(list(schema="w01-fast-october-historical-affected-source-v1",
 recovered_historical_works=length(records),recovered_historical_manifestations=length(seen),
 archived_canonical_bytes_transferred=total_bytes,
 raw_original_source_records_recovered=FALSE,
 independent_affected_canonical_parity_established=FALSE,works=records),
 file.path(out,"audit","report.json"),auto_unbox=TRUE,pretty=TRUE)
cat("PASS: all 44 historical affected canonical work records located with 177 historical manifestations\\n")
