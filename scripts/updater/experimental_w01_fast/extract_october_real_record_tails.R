#!/usr/bin/env Rscript
# Read-only ZIP64 STORED member extraction with hard transfer/size caps.
# Never downloads or unpacks the complete 27 GB GitHub Actions archive.
artifact_id <- "12257626610"
repo <- "thesalmonandthetomato/LivingEvidenceMap"
selected <- c(
 "previous_state/canonical/records.jsonl",
 "outputs/canonical/records.jsonl",
 "outputs/workflow01_union/cab_records_for_deduplication.jsonl",
 "outputs/workflow01_union/proquest_records_for_deduplication.jsonl"
)
out <- "selected_w01_october_record_tails"
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
total<-18178975846
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
if(!all(selected%in%names(entries)))stop("Required ZIP member absent")
if(sum(vapply(entries[selected],function(e)e$size,numeric(1)))>1600000000)
 stop("Total selected extraction exceeds 25 MB")
audit<-list()
for(name in selected){
 e<-entries[[name]]
 if(e$method!=0||e$size!=e$uncompressed||e$size>1000000000)
  stop("Unexpected compression method or oversized selected member")
 header<-tempfile();request(e$offset,e$offset+255,header,256)
 x<-readBin(header,"raw",n=256);unlink(header)
 if(!sig(x,0,c(0x50,0x4b,0x03,0x04)))stop("Bad local ZIP header")
 fname<-num(x,26,2);extra<-num(x,28,2)
 data_offset<-e$offset+30+fname+extra
 local_name<-rawToChar(x[31:(30+fname)])
 if(!identical(local_name,name))stop("Central/local name mismatch")
 dest<-file.path(out,name)
 dir.create(dirname(dest),showWarnings=FALSE,recursive=TRUE)
 if(e$size>0){
   # Read ONLY the last 4 MiB of the stored CSV member (never full 9.6GB).
   tail_n<-min(e$size,2097152)
   request(data_offset+e$size-tail_n,data_offset+e$size-1,dest,2097152)
 }else file.create(dest)
 audit[[name]]<-list(member_bytes=e$size,downloaded_tail_bytes=min(e$size,2097152),archive_offset=data_offset)
 cat(sprintf("Extracted %s (%.0f bytes)\n",name,e$size))
}
# Preserve a separate, small manifest. No archive or signed URL is retained.
jsonlite::write_json(list(schema="w01-fast-targeted-reference-v1",
 source_run_id=39400566861,archive_id=artifact_id,entries=audit,
 publication_allowed=FALSE),file.path(out,"metadata","extraction.json"),
 pretty=TRUE,auto_unbox=TRUE)
cat("PASS: bounded October W01 reference extraction completed\n")
