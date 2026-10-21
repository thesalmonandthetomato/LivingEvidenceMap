#!/usr/bin/env Rscript
# Read-only ZIP64 STORED member extraction with hard transfer/size caps.
# Never downloads or unpacks the complete 27 GB GitHub Actions archive.
artifact_id <- "12259032049"
repo <- "thesalmonandthetomato/LivingEvidenceMap"
selected <- c("outputs/canonical/records.jsonl")
out <- "actual_october_canonical_comparison"
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

if(!"outputs/canonical/records.jsonl"%in%names(entries))stop("Missing canonical reference")
e<-entries[["outputs/canonical/records.jsonl"]]
if(e$method!=0||e$size!=e$uncompressed||e$size>1000000000)stop("Invalid canonical ZIP member")
header<-tempfile();request(e$offset,e$offset+255,header,256)
x<-readBin(header,"raw",n=256);unlink(header)
if(!sig(x,0,c(0x50,0x4b,0x03,0x04)))stop("Bad stored ZIP local header")
fname<-num(x,26,2);extra<-num(x,28,2)
data_offset<-e$offset+30+fname+extra
if(!identical(rawToChar(x[31:(30+fname)]),"outputs/canonical/records.jsonl"))
 stop("Mismatched local archive member")
suppressPackageStartupMessages({library(data.table);library(jsonlite)})
test_path<-"real_new_work_fixture/canonical.jsonl"
if(!file.exists(test_path))stop("Missing independently materialised October works")
lines<-readLines(test_path,warn=FALSE)
ours<-lapply(lines,function(l)fromJSON(l,simplifyVector=FALSE))
ids<-vapply(ours,function(o)as.character(o$deduplication$cluster_id),character(1))
if(length(ids)!=16L||anyDuplicated(ids))stop("Expected exactly 16 distinct work IDs")
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
# Production writes canonical works in sorted cluster-ID order (also checked
# independently on previous/final archive tails). Fail if any sought ID is missing.
canonical_fields<-c("identity","canonical","manifestations","deduplication")
results<-vector("list",length(ids))
for(i in seq_along(ids)){
 ref<-find_work(ids[[i]]);fast<-ours[[i]]
 different<-canonical_fields[!vapply(canonical_fields,function(field)
   identical(ref[[field]],fast[[field]]),logical(1))]
 results[[i]]<-list(work_id=ids[[i]],scientific_fields_equal=!length(different),
 differing_fields=as.list(different),
 reference_keys=as.list(names(ref)),
 generated_keys=as.list(names(fast)))
 cat(sprintf("COMPARED %d/16 %s scientific differences=%d transfer=%.1fMiB\\n",
 i,ids[[i]],length(different),total_bytes/1048576))
}
dir.create(file.path(out,"audit"),recursive=TRUE)
write_json(list(schema="w01-fast-october-real-16-canonical-scientific-parity-v1",
 reference_archive_id=artifact_id,
 compared_works=length(results),
 scientific_fields=as.list(canonical_fields),
 mismatch_works=sum(!vapply(results,function(x)x$scientific_fields_equal,logical(1))),
 transferred_bytes=total_bytes,
 exact_full_jsonl_provenance_parity_established=FALSE,
 production_publication_allowed=FALSE,
 results=results),
 file.path(out,"audit","comparison.json"),auto_unbox=TRUE,pretty=TRUE)
if(any(!vapply(results,function(x)x$scientific_fields_equal,logical(1))))
 stop("One or more actual October scientific canonical work fields differed")
cat("PASS: 16 real October new works match production scientific canonical fields\\n")
